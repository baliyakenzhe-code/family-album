#!/usr/bin/perl
# Папки по людям и названия событий для уже разложенного альбома.
#   perl people.pl --sheet   собрать контактный лист (по нему Claude заполнит «люди.txt»)
#   perl people.pl --apply   разложить по папке «Люди» и переименовать события
# Файлы не копируются, а связываются жёсткими ссылками — место на диске не тратится.
use strict;
use warnings;
use utf8;
use Getopt::Long;
use File::Find ();
use File::Path qw(make_path);
use File::Basename qw(basename dirname);
use File::Spec ();
use Encode ();

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

my %opt = (
    album => 'Альбом',
    map   => 'люди.txt',
    sheet => 0,
    apply => 0,
    per   => 4,
);
GetOptions(\%opt, 'album=s', 'map=s', 'sheet!', 'apply!', 'per=i', 'help!')
    or die "Непонятный аргумент. Запустите с --help\n";

if ($opt{help} || (!$opt{sheet} && !$opt{apply})) { print usage(); exit 0 }
die "Нет папки «$opt{album}». Сначала разложите архив: perl sort-album.pl --apply\n"
    unless -d $opt{album};

my @MEDIA = qw(jpg jpeg png heic heif gif webp mp4 mov m4v);
my $MEDIA_RE = '\.(' . join('|', @MEDIA) . ')$';

$opt{sheet} ? build_sheet() : apply_map();

# ---------------- контактный лист ----------------

sub build_sheet {
    my @dirs = event_dirs();
    die "В «$opt{album}» не нашлось папок с событиями.\n" unless @dirs;

    my $tmp = File::Spec->catdir(File::Spec->tmpdir, 'album-sheet');
    system('rm', '-rf', $tmp);
    make_path("$tmp/thumbs");

    my (@cells, $n);
    for my $dir (@dirs) {
        my @files = media_in($dir);
        next unless @files;
        my $step = @files > $opt{per} ? int(@files / $opt{per}) : 1;
        my @pick;
        for (my $i = 0; $i < @files && @pick < $opt{per}; $i += $step) {
            push @pick, $files[$i];
        }
        for my $f (@pick) {
            $n++;
            my $thumb = sprintf('%s/thumbs/%03d.jpg', $tmp, $n);
            next unless system('sips', '-Z', '420', '-s', 'format', 'jpeg',
                               '-s', 'formatOptions', '55', $f, '--out', $thumb) == 0;
            push @cells, { n => $n, dir => rel($dir), file => basename($f), thumb => "thumbs/" . sprintf('%03d.jpg', $n) };
        }
    }
    die "Не удалось сделать ни одной миниатюры.\n" unless @cells;

    open(my $fh, '>:encoding(UTF-8)', "$tmp/sheet.html") or die "не могу создать лист: $!\n";
    print $fh '<!doctype html><meta charset=utf-8><style>'
        . 'body{margin:0;background:#fff;font:11px -apple-system,sans-serif}'
        . '.g{display:grid;grid-template-columns:repeat(6,1fr);gap:4px;padding:4px}'
        . '.c img{width:100%;height:120px;object-fit:cover;display:block}'
        . '.c b{display:block;background:#222;color:#fff;font-size:9px;padding:1px;overflow:hidden;white-space:nowrap}'
        . '</style><div class=g>';
    for my $c (@cells) {
        printf $fh '<div class=c><b>%d %s</b><img src="%s"></div>', $c->{n}, esc($c->{dir}), $c->{thumb};
    }
    print $fh '</div>';
    close $fh;

    my $png = "$tmp/sheet.png";
    system('rm', '-rf', "$tmp/ql");
    make_path("$tmp/ql");
    system('qlmanage', '-t', '-s', '1400', '-o', "$tmp/ql", "$tmp/sheet.html");
    my ($rendered) = glob("$tmp/ql/*.png");
    rename($rendered, $png) if $rendered;

    open(my $idx, '>:encoding(UTF-8)', "$tmp/index.txt") or die $!;
    print $idx "$_->{n}\t$_->{dir}\t$_->{file}\n" for @cells;
    close $idx;

    print "Кадров на листе: ", scalar @cells, " из ", scalar @dirs, " папок\n";
    print "Картинка:  $png\n" if -e $png;
    print "Страница:  $tmp/sheet.html\n";
    print "Расшифровка номеров: $tmp/index.txt\n\n";
    print "Дальше: покажите картинку Claude — он заполнит «$opt{map}»,\n";
    print "потом:  perl people.pl --apply\n";
}

# ---------------- раскладка по людям ----------------

sub apply_map {
    die "Нет файла «$opt{map}». Сначала: perl people.pl --sheet\n" unless -e $opt{map};

    open(my $fh, '<:encoding(UTF-8)', $opt{map}) or die "не читается $opt{map}: $!\n";
    my (%people, %title);
    while (my $line = <$fh>) {
        $line =~ s/\s+$//;
        next if $line =~ /^\s*(#|$)/;
        my ($dir, $rest) = split /\s*=\s*/, $line, 2;
        next unless defined $rest;
        $dir =~ s/^\s+//;
        my ($who, $name) = split /\s*\|\s*/, $rest, 2;
        $people{$dir} = [ grep { length } map { s/^\s+|\s+$//gr } split /\s*,\s*/, ($who // '') ];
        $title{$dir}  = $name if defined $name && length $name;
    }
    close $fh;
    die "В «$opt{map}» нет ни одной строки вида «папка = Имя, Имя | Название».\n" unless %people;

    my ($linked, $renamed, $missing) = (0, 0, 0);
    for my $dir (sort keys %people) {
        my $full = resolve($dir);
        unless (defined $full) { warn "  нет папки: $dir\n"; $missing++; next }

        my @files = media_in($full);
        my %stem_has_original;
        $stem_has_original{ stem($_) } = 1 for grep { !/\.jpg$/i } @files;

        for my $who (@{ $people{$dir} }) {
            my ($year) = $dir =~ m{(\d{4})};
            my $target = File::Spec->catdir($opt{album}, 'Люди', $who, $year // 'без года');
            make_path($target) unless -d $target;
            for my $f (@files) {
                next if $f =~ /\.jpg$/i && $stem_has_original{ stem($f) };
                my $dst = File::Spec->catfile($target, basename($f));
                next if -e $dst;
                link($f, $dst) or symlink($f, $dst) or next;
                $linked++;
            }
        }
    }

    for my $dir (sort keys %title) {
        my $full = resolve($dir);
        next unless defined $full;
        # Имя строим из строки разметки, а не из текущей папки: иначе при повторном
        # запуске название события приклеилось бы второй раз.
        my $base = basename(File::Spec->catdir($opt{album}, $dir));
        $base =~ s/\s*—\s*разное\s*$//;
        my $new = File::Spec->catdir(dirname($full), "$base — $title{$dir}");
        next if $new eq $full;
        next if -e $new;
        rename($full, $new) and $renamed++;
    }

    print "Ссылок в папке «Люди»: $linked\n";
    print "Переименовано событий: $renamed\n" if $renamed;
    print "Папок не найдено: $missing\n" if $missing;
    print "\nГотово. Смотрите $opt{album}/Люди\n";
}

# ---------------- вспомогательное ----------------

sub event_dirs {
    my @dirs;
    for my $cat ('События', 'Путешествия', 'Без даты') {
        my $root = File::Spec->catdir($opt{album}, $cat);
        next unless -d $root;
        File::Find::find({
            no_chdir => 1,
            wanted   => sub {
                return unless -d $File::Find::name;
                return if $File::Find::name eq $root;
                push @dirs, $File::Find::name if media_in($File::Find::name);
            },
        }, $root);
    }
    return sort @dirs;
}

sub media_in {
    my ($dir) = @_;
    opendir(my $dh, $dir) or return ();
    my @f = sort grep { -f && /$MEDIA_RE/i }
            map { File::Spec->catfile($dir, $_) }
            grep { !/^\./ } readdir($dh);
    closedir $dh;
    return @f;
}

sub stem { my $b = basename($_[0]); $b =~ s/\.[^.]+$//; return $b }

# Папку могли уже переименовать, добавив название события. Сравниваем по датовой
# части имени: она из цифр и дефисов, поэтому не зависит от того, как macOS
# хранит кириллицу в именах файлов.
sub resolve {
    my ($dir) = @_;
    my $full = File::Spec->catdir($opt{album}, $dir);
    return $full if -d $full;

    my ($date) = basename($full) =~ /^(\d{4}-\d{2}(?:-\d{2})?)/;
    return undef unless $date;
    my $parent = dirname($full);
    return undef unless -d $parent;

    opendir(my $dh, $parent) or return undef;
    my @entries = map { Encode::decode('UTF-8', $_, Encode::FB_DEFAULT()) } readdir($dh);
    closedir $dh;
    my @hit = sort grep { index($_, $date) == 0 && -d File::Spec->catdir($parent, $_) }
              grep { !/^\./ } @entries;
    return @hit ? File::Spec->catdir($parent, $hit[0]) : undef;
}

sub rel {
    my ($p) = @_;
    my $a = quotemeta($opt{album});
    $p =~ s{^$a/}{};
    return $p;
}

sub esc {
    my ($s) = @_;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    return $s;
}

sub usage {
    return <<'TXT';
Папки по людям для уже разложенного альбома.

  perl people.pl --sheet    собрать контактный лист из всех папок событий
  perl people.pl --apply    применить «люди.txt»: папка «Люди» + названия событий

Файл «люди.txt» — по строке на папку события:

  События/2021/2021-09 — разное = Хайдар, Балия | День рождения Хайдара
  Путешествия/2024/2024-08-14 — 08-15 = Хайдар, Балия | Байконур

  слева  — путь папки внутри «Альбом»
  справа — кто на снимках, через запятую
  после «|» — название события (необязательно, добавится к имени папки)

Настройки:
  --album «папка»   где лежит разложенный архив (по умолчанию «Альбом»)
  --map «файл»      файл с разметкой (по умолчанию «люди.txt»)
  --per 4           сколько кадров с каждой папки брать на лист
TXT
}
