#!/usr/bin/perl
# Готовит фотографии из «Альбом» к заливке в опубликованный альбом:
# уменьшает до 1900 px и собирает метаданные (раздел, год, подпись) в JSON.
#
# Внимание: скрипт намеренно работает с именами файлов как с байтами (без use utf8).
# macOS отдаёт их из readdir в UTF-8, и любое смешивание с «символьными» строками
# ломает кириллические пути.
use strict;
use warnings;
use Getopt::Long;
use File::Find ();
use File::Path qw(make_path remove_tree);
use File::Basename qw(basename);
use File::Spec ();
use JSON::PP ();

my %opt = (
    album => 'Альбом',
    map   => 'люди.txt',
    out   => 'выгрузка',
    max   => 1900,
    q     => 86,
);
GetOptions(\%opt, 'album=s', 'map=s', 'out=s', 'max=i', 'q=i', 'help!')
    or die "Непонятный аргумент\n";
if ($opt{help}) { print usage(); exit 0 }
die "Нет папки «$opt{album}»\n" unless -d $opt{album};

# Разделы альбома — идентификаторы из index.html
my %SECTION = (
    'Хайдар' => 'haidar',
    'Балия'  => 'balia',
    'Ата'    => 'papa',
    'Аже'    => 'mama',
);

# ---- разметка людей: ключ — датовая часть имени папки ----
my %people;
if (-e $opt{map}) {
    open(my $fh, '<', $opt{map}) or die "не читается $opt{map}: $!\n";
    while (my $l = <$fh>) {
        $l =~ s/\s+$//;
        next if $l =~ /^\s*(#|$)/;
        my ($dir, $rest) = split /\s*=\s*/, $l, 2;
        next unless defined $rest;
        $dir =~ s/^\s+//;
        my ($who) = split /\s*\|\s*/, $rest, 2;
        my ($date) = basename($dir) =~ /^(\d{4}-\d{2}(?:-\d{2})?)/;
        next unless $date;
        my @names = grep { length } map { my $n = $_; $n =~ s/^\s+|\s+$//g; $n }
                    split /\s*,\s*/, ($who // '');
        $people{$date} = \@names;
    }
    close $fh;
}

# ---- собираем фотографии ----
my @photos;
File::Find::find({
    no_chdir => 1,
    wanted   => sub {
        my $p = $File::Find::name;
        return unless -f $p;
        return if index($p, '/Люди/') >= 0;
        return if basename($p) =~ /^\./;
        return unless $p =~ /\.jpe?g$/i;
        push @photos, $p;
    },
}, $opt{album});

die "Фотографий не нашлось в «$opt{album}»\n" unless @photos;
printf "Нашёл фотографий: %d\n", scalar @photos;

remove_tree($opt{out}) if -d $opt{out};
make_path($opt{out});

my (@records, @skipped);
my $i = 0;
for my $src (sort @photos) {
    my $rel = $src;
    $rel =~ s/^\Q$opt{album}\E\///;

    my @parts = split m{/}, $rel;
    my $category = $parts[0] // '';
    my ($year)   = $rel =~ m{/(\d{4})/};

    if ($category eq 'Без даты' || !$year) {
        push @skipped, $rel;
        next;
    }

    my $folder = $parts[2] // '';
    my ($date) = $folder =~ /^(\d{4}-\d{2}(?:-\d{2})?)/;

    # название события — то, что после последнего « — »
    my @seg = split /\s+—\s+/, $folder;
    my $title = @seg > 1 ? $seg[-1] : '';
    $title = '' if $title eq 'разное' || $title =~ /^\d/;

    my @who = @{ $people{ $date // '' } || [] };
    my $section = $category eq 'Путешествия' ? 'travel'
                : (@who == 1 && $SECTION{ $who[0] }) ? $SECTION{ $who[0] }
                : 'family';

    $i++;
    my $dst = File::Spec->catfile($opt{out}, sprintf('%03d.jpg', $i));
    my $rc = system('sips', '-Z', $opt{max}, '-s', 'format', 'jpeg',
                    '-s', 'formatOptions', $opt{q}, $src, '--out', $dst);
    if ($rc != 0 || !-s $dst) { $i--; push @skipped, $rel; next }

    my ($w, $h) = (0, 0);
    open(my $ph, '-|', 'sips', '-g', 'pixelWidth', '-g', 'pixelHeight', $dst);
    while (my $line = <$ph>) {
        $w = $1 if $line =~ /pixelWidth:\s*(\d+)/;
        $h = $1 if $line =~ /pixelHeight:\s*(\d+)/;
    }
    close $ph;

    push @records, {
        file    => basename($dst),
        section => $section,
        year    => $year + 0,
        caption => $title,
        w       => $w + 0,
        h       => $h + 0,
        people  => \@who,
        source  => $rel,
    };
}

open(my $out, '>', File::Spec->catfile($opt{out}, 'meta.json')) or die $!;
print $out JSON::PP->new->pretty->canonical->encode(\@records);
close $out;

my %by;
$by{ $_->{section} }++ for @records;
my $bytes = 0;
$bytes += -s File::Spec->catfile($opt{out}, $_->{file}) for @records;

printf "\nПодготовлено: %d\n", scalar @records;
printf "  %-8s %d\n", $_, $by{$_} for sort keys %by;
printf "Общий вес: %.1f МБ (в хранилище альбома 1024 МБ)\n", $bytes / 1048576;
printf "Пропущено: %d (без даты или не удалось уменьшить)\n", scalar @skipped if @skipped;
print "Папка: $opt{out}\n";

sub usage {
    return <<'TXT';
Готовит фото к заливке в опубликованный альбом.

  perl upload-prep.pl              уменьшить и собрать метаданные
  perl upload-prep.pl --max 1600   другая длинная сторона

  --album «папка»  разложенный архив (по умолчанию «Альбом»)
  --map «файл»     разметка людей (по умолчанию «люди.txt»)
  --out «папка»    куда сложить готовое (по умолчанию «выгрузка»)
TXT
}
