#!/usr/bin/perl
# Раскладывает фото и видео из папки «Входящие» по событиям, годам и путешествиям.
# Работает на штатном macOS: метаданные из sips/mdls, конвертация HEIC — sips. Ничего ставить не нужно.
use strict;
use warnings;
use utf8;
use Getopt::Long;
use File::Find ();
use File::Copy qw(copy move);
use File::Path qw(make_path);
use File::Basename qw(basename);
use File::Spec ();
use Time::Local qw(timegm);
use Digest::MD5 ();
use POSIX qw(strftime);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

my %opt = (
    in     => '00 Входящие',
    out    => 'Альбом',
    gap    => 6,      # часов тишины => новое событие
    jump   => 25,     # км смещения => новое событие
    travel => 100,    # км от дома => путешествие
    min    => 3,      # событие меньше этого — не отдельная папка, а «месяц, разное»
    apply  => 0,
    move   => 0,
    jpeg   => 0,
    home   => '',
);
GetOptions(\%opt, 'in=s', 'out=s', 'gap=f', 'jump=f', 'travel=f', 'min=i',
                  'apply!', 'move!', 'jpeg!', 'home=s', 'help!')
    or die "Непонятный аргумент. Запустите с --help\n";

if ($opt{help}) { print usage(); exit 0 }
die "Папки «$opt{in}» нет. Создайте её и сложите туда файлы.\n" unless -d $opt{in};
die "--move работает только вместе с --apply\n" if $opt{move} && !$opt{apply};

my @EXT = qw(jpg jpeg png heic heif gif webp tif tiff mp4 mov m4v avi);
my %IS_VIDEO = map { $_ => 1 } qw(mp4 mov m4v avi);
my $EXT_RE = '\.(' . join('|', @EXT) . ')$';

# Смещение часового пояса: даты внутри mp4 лежат в UTC, а раскладываем по местным дням.
my $TZ_SHIFT = timegm(localtime(time)) - time;

# ---------- 1. собираем файлы ----------
my @files;
File::Find::find({
    no_chdir => 1,
    wanted   => sub {
        my $p = $File::Find::name;
        return unless -f $p;
        return if basename($p) =~ /^\./;
        return unless $p =~ /$EXT_RE/i;
        push @files, $p;
    },
}, $opt{in});

die "В «$opt{in}» не нашлось ни фото, ни видео.\n" unless @files;
printf "Нашёл файлов: %d\n", scalar @files;

# Свежескопированные файлы Spotlight мог ещё не увидеть, а GPS достаётся только из его индекса.
print "Обновляю индекс Spotlight…\n";
system('mdimport', $opt{in});

print "Читаю метаданные…\n";

# ---------- 2. метаданные ----------
my (@items, @nodate, @dupes);
my %seen;
my $done = 0;

for my $path (@files) {
    $done++;
    printf "\r  %d/%d", $done, scalar @files if $done % 20 == 0 || $done == @files;

    my $sig = quick_sig($path);
    if (defined $sig && $seen{$sig}) {
        push @dupes, $path;
        next;
    }
    $seen{$sig} = $path if defined $sig;

    my ($ext) = $path =~ /$EXT_RE/i;
    $ext = lc($ext // '');

    my $m = read_meta($path, $ext);
    my $it = {
        path  => $path,
        ext   => $ext,
        kind  => $IS_VIDEO{$ext} ? 'video' : 'image',
        epoch => $m->{epoch},
        lat   => $m->{lat},
        lon   => $m->{lon},
        w     => $m->{w} || 0,
        h     => $m->{h} || 0,
        dur   => $m->{dur} || 0,
        model => $m->{model} || '',
    };
    defined $it->{epoch} ? push(@items, $it) : push(@nodate, $it);
}
print "\n";

# ---------- 3. свои места ----------
# Свои места — те, куда возвращаются годами. Одна долгая поездка так не выглядит,
# поэтому она останется путешествием, а регулярные визиты в другой город — нет.
my @own;
if ($opt{home} =~ /^\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*$/) {
    @own = ({ lat => $1 + 0, lon => $2 + 0, days => 0, manual => 1 });
} else {
    @own = own_places(\@items);
    unless (@own) {
        my ($la, $lo) = guess_home(\@items);
        @own = ({ lat => $la, lon => $lo, days => 0 }) if defined $la;
    }
}
my ($home_lat, $home_lon) = @own ? ($own[0]{lat}, $own[0]{lon}) : (undef, undef);

# ---------- 4. события ----------
@items = sort { $a->{epoch} <=> $b->{epoch} } @items;

my @events;
for my $it (@items) {
    my $ev = @events ? $events[-1] : undef;
    my $split = 1;
    if ($ev) {
        my $quiet  = ($it->{epoch} - $ev->{last_epoch}) > $opt{gap} * 3600;
        my $jumped = 0;
        if (defined $it->{lat} && defined $ev->{lat}) {
            $jumped = km($it->{lat}, $it->{lon}, $ev->{lat}, $ev->{lon}) > $opt{jump};
        }
        $split = ($quiet || $jumped);
    }
    if ($split) {
        push @events, {
            items       => [],
            first_epoch => $it->{epoch},
            last_epoch  => $it->{epoch},
            gps_n       => 0,
            lat_sum     => 0,
            lon_sum     => 0,
        };
        $ev = $events[-1];
    }
    push @{ $ev->{items} }, $it;
    $ev->{last_epoch} = $it->{epoch};
    if (defined $it->{lat}) {
        $ev->{gps_n}++;
        $ev->{lat_sum} += $it->{lat};
        $ev->{lon_sum} += $it->{lon};
        $ev->{lat} = $ev->{lat_sum} / $ev->{gps_n};
        $ev->{lon} = $ev->{lon_sum} / $ev->{gps_n};
    }
}

# ---------- 5. категории, склейка поездок, имена ----------
for my $ev (@events) {
    next unless defined $ev->{lat} && @own;
    for my $p (@own) {
        next unless defined $p->{lat};
        my $d = km($ev->{lat}, $ev->{lon}, $p->{lat}, $p->{lon});
        $ev->{from_home} = $d if !defined $ev->{from_home} || $d < $ev->{from_home};
    }
}
for my $ev (@events) {
    $ev->{category} = (defined $ev->{from_home} && $ev->{from_home} > $opt{travel})
                    ? 'Путешествия' : 'События';
}

# Одна поездка — одна папка: соседние далёкие события рядом по месту и времени склеиваются.
my @merged;
for my $ev (@events) {
    my $prev = @merged ? $merged[-1] : undef;
    if (   $prev
        && $prev->{category} eq 'Путешествия'
        && $ev->{category} eq 'Путешествия'
        && ($ev->{first_epoch} - $prev->{last_epoch}) <= 3 * 86400
        && defined $prev->{lat} && defined $ev->{lat}
        && km($prev->{lat}, $prev->{lon}, $ev->{lat}, $ev->{lon}) <= 150)
    {
        push @{ $prev->{items} }, @{ $ev->{items} };
        $prev->{last_epoch} = $ev->{last_epoch};
        $prev->{from_home} = $ev->{from_home}
            if defined $ev->{from_home}
            && (!defined $prev->{from_home} || $ev->{from_home} > $prev->{from_home});
        next;
    }
    push @merged, $ev;
}
@events = @merged;

my %used;
for my $ev (@events) {
    $ev->{year} = strftime('%Y', gmtime $ev->{first_epoch});

    if (@{ $ev->{items} } < $opt{min}) {
        $ev->{name}   = strftime('%Y-%m', gmtime $ev->{first_epoch}) . ' — разное';
        $ev->{single} = 1;
    } else {
        my $d1 = strftime('%Y-%m-%d', gmtime $ev->{first_epoch});
        my $d2 = strftime('%Y-%m-%d', gmtime $ev->{last_epoch});
        my $name = ($d1 eq $d2) ? $d1
                 : "$d1 — " . strftime('%m-%d', gmtime $ev->{last_epoch});
        my $key = "$ev->{category}/$ev->{year}/$name";
        $name .= ' #' . $used{$key} if $used{$key}++;
        $ev->{name} = $name;
    }
    $ev->{dir} = File::Spec->catdir($opt{out}, $ev->{category}, $ev->{year}, $ev->{name});
}

# ---------- 6. отчёт ----------
my $with_gps = grep { defined $_->{lat} } @items;

print "\n", '=' x 66, "\n";
if (defined $home_lat) {
    printf "Свои места: %d%s\n", scalar @own, ($opt{home} ? ' (задано вручную)' : '');
    my $shown = 0;
    for my $p (@own) {
        last if $shown++ >= 4;
        printf "   %.3f, %.3f%s\n", $p->{lat}, $p->{lon},
            ($p->{days} ? sprintf(' — съёмки в %d разных дней', $p->{days}) : '');
    }
} else {
    print "Свои места определить не удалось — ни у одного файла нет GPS.\n";
}
printf "Событий: %d  ·  файлов с датой: %d  ·  без даты: %d  ·  дубликатов: %d\n",
    scalar @events, scalar @items, scalar @nodate, scalar @dupes;
printf "С координатами: %d из %d\n", $with_gps, scalar @items;
print '=' x 66, "\n\n";

if (!$with_gps && @items > 20) {
    print "! GPS не нашёлся ни у одного файла. Путешествия отличить не получится.\n";
    print "  Обычно это значит, что Spotlight не индексирует эту папку. Проверить:\n";
    print "      mdutil -s /\n\n";
}

for my $cat ('События', 'Путешествия') {
    my @in_cat = grep { $_->{category} eq $cat } @events;
    next unless @in_cat;
    printf "── %s %s\n", $cat, '─' x (62 - length $cat);

    my (%agg, @order);
    for my $ev (@in_cat) {
        my $key = "$ev->{year}/$ev->{name}";
        unless ($agg{$key}) {
            $agg{$key} = { n => 0, v => 0, far => undef };
            push @order, $key;
        }
        $agg{$key}{n} += @{ $ev->{items} };
        $agg{$key}{v} += grep { $_->{kind} eq 'video' } @{ $ev->{items} };
        $agg{$key}{far} = $ev->{from_home}
            if defined $ev->{from_home}
            && (!defined $agg{$key}{far} || $ev->{from_home} > $agg{$key}{far});
    }
    for my $key (sort @order) {
        my $a = $agg{$key};
        printf "  %-30s %s%s%s\n", $key, plural($a->{n}),
            ($a->{v} ? ", видео: $a->{v}" : ''),
            (defined $a->{far} ? sprintf(' · %.0f км от дома', $a->{far}) : ' · без GPS');
    }
    print "\n";
}
printf "── Без даты %s\n  %s → %s/Без даты\n\n", '─' x 55, plural(scalar @nodate), $opt{out} if @nodate;
printf "── Дубликаты %s\n  %s → %s/_Дубликаты\n\n", '─' x 54, plural(scalar @dupes), $opt{out} if @dupes;

unless ($opt{apply}) {
    print "Это предпросмотр — ни один файл не тронут.\n\n";
    print "  perl sort-album.pl --apply           разложить копии по папкам\n";
    print "  perl sort-album.pl --apply --move    перенести (во «Входящих» не останется)\n";
    print "  perl sort-album.pl --apply --jpeg    плюс JPEG-копии для HEIC\n";
    exit 0;
}

# ---------- 7. раскладываем ----------
print($opt{move} ? "Перемещаю файлы…\n" : "Копирую файлы…\n");
my ($ok, $fail, $conv) = (0, 0, 0);
my @manifest;

for my $ev (@events) {
    for my $it (@{ $ev->{items} }) {
        my $dst = place($it->{path}, $ev->{dir});
        unless ($dst) { $fail++; next }
        $ok++;
        push @manifest, row($it, $dst, $ev);
        $conv++ if $opt{jpeg} && $it->{ext} =~ /^hei[cf]$/ && to_jpeg($dst);
    }
}
for my $it (@nodate) {
    my $dst = place($it->{path}, File::Spec->catdir($opt{out}, 'Без даты'));
    unless ($dst) { $fail++; next }
    $ok++;
    push @manifest, row($it, $dst, { category => 'Без даты', year => '', name => '' });
}
for my $d (@dupes) {
    place($d, File::Spec->catdir($opt{out}, '_Дубликаты')) ? $ok++ : $fail++;
}

write_manifest(\@manifest);

printf "\nГотово. Разложено: %d%s%s\n", $ok,
    ($fail ? ", не удалось: $fail" : ''),
    ($conv ? ", JPEG-копий: $conv" : '');
print "Результат: $opt{out}\n";
print "Таблица метаданных: $opt{out}/manifest.csv\n";

# ================= вспомогательное =================

sub read_meta {
    my ($path, $ext) = @_;
    my %m;

    unless ($IS_VIDEO{$ext}) {
        my $s = backtick('sips', '-g', 'all', $path);
        $m{epoch} = parse_sips_date($1) if $s =~ /^\s*creation:\s*(\S+\s+\S+)/m;
        $m{w}     = $1 if $s =~ /^\s*pixelWidth:\s*(\d+)/m;
        $m{h}     = $1 if $s =~ /^\s*pixelHeight:\s*(\d+)/m;
        $m{model} = $1 if $s =~ /^\s*model:\s*(.+?)\s*$/m;
    }

    # У части камер (например, дронов DJI) настоящая дата есть только в имени файла.
    $m{epoch} //= date_from_name(basename($path));
    $m{epoch} //= mp4_creation($path) if $IS_VIDEO{$ext};

    my $md = read_mdls($path);
    $m{lat}   //= num($md->{kMDItemLatitude});
    $m{lon}   //= num($md->{kMDItemLongitude});
    $m{dur}   //= num($md->{kMDItemDurationSeconds});
    $m{w}     //= num($md->{kMDItemPixelWidth});
    $m{h}     //= num($md->{kMDItemPixelHeight});
    $m{model} //= $md->{kMDItemAcquisitionModel};

    # ContentCreationDate у файлов без EXIF подменяется датой появления файла на диске,
    # и тогда картинки с сайта склеиваются в «событие» дня, когда их скачали.
    # Поэтому берём её только там, где есть следы камеры.
    if (!defined $m{epoch} && ($m{model} || defined $m{lat})) {
        $m{epoch} = parse_mdls_date($md->{kMDItemContentCreationDate});
    }

    delete $m{lon} unless defined $m{lat};
    delete $m{lat} unless defined $m{lon};
    return \%m;
}

sub read_mdls {
    my ($path) = @_;
    my %md;
    for my $line (split /\n/, backtick('mdls', $path)) {
        next unless $line =~ /^(kMDItem\w+)\s+=\s+(.*?)\s*$/;
        my ($k, $v) = ($1, $2);
        next if $v eq '(null)';
        $v =~ s/^"(.*)"$/$1/;
        $md{$k} = $v;
    }
    return \%md;
}

sub backtick {
    my @cmd = @_;
    my $pid = open(my $fh, '-|');
    return '' unless defined $pid;
    unless ($pid) {
        open(STDERR, '>', '/dev/null');
        exec @cmd;
        exit 1;
    }
    local $/;
    my $out = <$fh>;
    close $fh;
    return defined $out ? $out : '';
}

# size + md5 первого мегабайта: для поиска дублей этого достаточно, а считается мгновенно
sub quick_sig {
    my ($path) = @_;
    my $size = -s $path;
    return undef unless $size;
    open(my $fh, '<:raw', $path) or return undef;
    my $buf = '';
    read($fh, $buf, 1048576);
    close $fh;
    return $size . ':' . Digest::MD5::md5_hex($buf);
}

sub parse_sips_date {
    my ($s) = @_;
    return undef unless $s =~ /^(\d{4}):(\d{2}):(\d{2})\s+(\d{2}):(\d{2}):(\d{2})/;
    return undef if $1 < 1900;
    return timegm($6, $5, $4, $3, $2 - 1, $1);
}

sub parse_mdls_date {
    my ($s) = @_;
    return undef unless defined $s && $s =~ /^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})/;
    return timegm($6, $5, $4, $3, $2 - 1, $1) + $TZ_SHIFT;
}

sub date_from_name {
    my ($name) = @_;
    my ($y, $mo, $d, $h, $mi, $s);
    if ($name =~ /(19[89]\d|20[0-3]\d)[-_.]?(\d{2})[-_.]?(\d{2})[-_.T ]?(\d{2})[-_.:]?(\d{2})[-_.:]?(\d{2})/) {
        ($y, $mo, $d, $h, $mi, $s) = ($1, $2, $3, $4, $5, $6);
    } elsif ($name =~ /(19[89]\d|20[0-3]\d)[-_.](\d{2})[-_.](\d{2})/) {
        ($y, $mo, $d, $h, $mi, $s) = ($1, $2, $3, 12, 0, 0);
    } else {
        return undef;
    }
    return undef if $mo < 1 || $mo > 12 || $d < 1 || $d > 31;
    return undef if $h > 23 || $mi > 59 || $s > 59;
    return timegm($s, $mi, $h, $d, $mo - 1, $y);
}

# Дата съёмки из атома mvhd внутри mp4/mov (секунды от 1904-01-01 UTC)
sub mp4_creation {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    my $t = find_mvhd($fh, 0, -s $path, 0);
    close $fh;
    return undef unless $t && $t > 2082844800;
    return $t - 2082844800 + $TZ_SHIFT;
}

sub find_mvhd {
    my ($fh, $start, $end, $depth) = @_;
    return undef if $depth > 3;
    my $pos = $start;
    while ($pos < $end - 8) {
        seek($fh, $pos, 0) or return undef;
        my $hdr = '';
        return undef unless read($fh, $hdr, 8) == 8;
        my ($size, $type) = unpack('N a4', $hdr);
        my $hs = 8;
        if ($size == 1) {
            my $b = '';
            return undef unless read($fh, $b, 8) == 8;
            my ($hi, $lo) = unpack('NN', $b);
            $size = $hi * 4294967296 + $lo;
            $hs = 16;
        } elsif ($size == 0) {
            $size = $end - $pos;
        }
        return undef if $size < $hs;

        if ($type eq 'mvhd') {
            my $b = '';
            return undef unless read($fh, $b, 20) >= 12;
            my $ver = unpack('C', substr($b, 0, 1));
            if ($ver == 1) {
                my ($hi, $lo) = unpack('NN', substr($b, 4, 8));
                return $hi * 4294967296 + $lo;
            }
            return unpack('N', substr($b, 4, 4));
        }
        if ($type eq 'moov') {
            my $r = find_mvhd($fh, $pos + $hs, $pos + $size, $depth + 1);
            return $r if $r;
        }
        $pos += $size;
    }
    return undef;
}

sub plural {
    my ($n) = @_;
    my $last = $n % 10;
    my $two  = $n % 100;
    return "$n файлов" if $two >= 11 && $two <= 14;
    return "$n файл"   if $last == 1;
    return "$n файла"  if $last >= 2 && $last <= 4;
    return "$n файлов";
}

sub num {
    my ($v) = @_;
    return undef unless defined $v && $v =~ /^-?[\d.]+$/;
    return $v + 0;
}

sub km {
    my ($la1, $lo1, $la2, $lo2) = @_;
    my $rad = atan2(1, 1) * 4 / 180;
    my $dla = ($la2 - $la1) * $rad;
    my $dlo = ($lo2 - $lo1) * $rad;
    my $a = sin($dla / 2) ** 2
          + cos($la1 * $rad) * cos($la2 * $rad) * sin($dlo / 2) ** 2;
    $a = 1 if $a > 1;
    return 6371 * 2 * atan2(sqrt($a), sqrt(1 - $a));
}

sub own_places {
    my ($list) = @_;
    my %cell;
    for my $it (@$list) {
        next unless defined $it->{lat};
        my $k = sprintf('%.1f,%.1f', $it->{lat}, $it->{lon});
        $cell{$k}{days}{ int($it->{epoch} / 86400) } = 1;
        $cell{$k}{lat} += $it->{lat};
        $cell{$k}{lon} += $it->{lon};
        $cell{$k}{n}++;
    }
    my @places;
    for my $k (keys %cell) {
        my @days = sort { $a <=> $b } keys %{ $cell{$k}{days} };
        next if @days < 3;
        next if ($days[-1] - $days[0]) < 180;
        push @places, {
            lat  => $cell{$k}{lat} / $cell{$k}{n},
            lon  => $cell{$k}{lon} / $cell{$k}{n},
            days => scalar @days,
        };
    }
    return sort { $b->{days} <=> $a->{days} } @places;
}

sub guess_home {
    my ($list) = @_;
    my %bucket;
    for my $it (@$list) {
        next unless defined $it->{lat};
        push @{ $bucket{ sprintf('%.1f,%.1f', $it->{lat}, $it->{lon}) } }, $it;
    }
    return (undef, undef) unless %bucket;
    my ($best) = sort { @{ $bucket{$b} } <=> @{ $bucket{$a} } } keys %bucket;
    my @pts = @{ $bucket{$best} };
    my ($sla, $slo) = (0, 0);
    for my $p (@pts) { $sla += $p->{lat}; $slo += $p->{lon} }
    return ($sla / @pts, $slo / @pts);
}

sub place {
    my ($src, $dir) = @_;
    make_path($dir) unless -d $dir;
    my $base = basename($src);
    my $dst  = File::Spec->catfile($dir, $base);

    if (-e $dst) {
        my $a = quick_sig($src) // 'a';
        my $b = quick_sig($dst) // 'b';
        return $dst if $a eq $b;
        my ($stem, $ext) = $base =~ /^(.*?)(\.[^.]*)?$/;
        my $n = 2;
        $n++ while -e ($dst = File::Spec->catfile($dir, "$stem ($n)" . ($ext // '')));
    }

    unless ($opt{move} ? move($src, $dst) : copy($src, $dst)) {
        warn "  не смог перенести: $src ($!)\n";
        return undef;
    }
    return $dst;
}

sub to_jpeg {
    my ($heic) = @_;
    (my $jpg = $heic) =~ s/\.hei[cf]$/.jpg/i;
    return 0 if -e $jpg;
    return system('sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '86',
                  $heic, '--out', $jpg) == 0 ? 1 : 0;
}

sub row {
    my ($it, $dst, $ev) = @_;
    return {
        target   => $dst,
        category => $ev->{category},
        event    => $ev->{name},
        year     => $ev->{year} || ($it->{epoch} ? strftime('%Y', gmtime $it->{epoch}) : ''),
        shot_at  => $it->{epoch} ? strftime('%Y-%m-%d %H:%M:%S', gmtime $it->{epoch}) : '',
        kind     => $it->{kind},
        lat      => (defined $it->{lat} ? sprintf('%.6f', $it->{lat}) : ''),
        lon      => (defined $it->{lon} ? sprintf('%.6f', $it->{lon}) : ''),
        w        => $it->{w},
        h        => $it->{h},
        seconds  => ($it->{dur} ? sprintf('%.1f', $it->{dur}) : ''),
        camera   => $it->{model},
        source   => $it->{path},
    };
}

sub write_manifest {
    my ($rows) = @_;
    my @cols = qw(target category event year shot_at kind lat lon w h seconds camera source);
    make_path($opt{out}) unless -d $opt{out};
    my $file = File::Spec->catfile($opt{out}, 'manifest.csv');
    open(my $fh, '>:encoding(UTF-8)', $file)
        or do { warn "не смог записать manifest: $!\n"; return };
    print $fh join(',', @cols), "\n";
    for my $r (@$rows) {
        print $fh join(',', map { csv($r->{$_}) } @cols), "\n";
    }
    close $fh;
}

sub csv {
    my ($v) = @_;
    $v = '' unless defined $v;
    return $v unless $v =~ /[",\n]/;
    $v =~ s/"/""/g;
    return qq{"$v"};
}

sub usage {
    return <<'TXT';
Раскладывает фото и видео по событиям, годам и путешествиям.

  perl sort-album.pl                     предпросмотр, ничего не меняет
  perl sort-album.pl --apply             скопировать в папки
  perl sort-album.pl --apply --move      перенести (во «Входящих» не останется)
  perl sort-album.pl --apply --jpeg      плюс JPEG-копии для HEIC (для альбома)

Настройки:
  --in  «папка»      откуда брать (по умолчанию «00 Входящие»)
  --out «папка»      куда раскладывать (по умолчанию «Альбом»)
  --gap  6           часов тишины, после которых начинается новое событие
  --jump 25          км смещения, после которых начинается новое событие
  --travel 100       км от дома, дальше которых событие считается путешествием
  --min 3            событие меньше N файлов уходит в «ГОД-МЕС — разное»
  --home 43.2,76.9   координаты дома вручную (иначе — самая частая точка съёмки)
TXT
}
