#!/usr/bin/perl

use strict;
use warnings;

use Data::Dumper;
use Digest::MD5 qw(md5_hex);
use File::Path qw(make_path);
use File::Slurp qw(slurp write_file);
use File::Spec::Functions;
use IO::Handle;
use Pod::Usage;

autoflush STDOUT 1;

die "Usage: $0 [pg_dump -s file [save to path]]" unless (@ARGV == 1 || @ARGV == 2);

my $schema    = slurp($ARGV[0]);
my $save_path = $ARGV[1] || 'schema';

die "Directory '$save_path' is invalid, must be ^[a-zA-Z0-9_]+\$" unless $save_path =~ m/^[a-zA-Z0-9_]+$/;
die "Directory '$save_path' already exists" if -d $save_path;

my @objects;
my $i = 0;

my %regexes = (
    definitions => qr{
        AS\ (\$[^\$]*\$)        # $1: opening identifier, example: AS $_$
        ((?![0-9a-f]{32}).*?)   # $2: definition
        \1                      # closing identifier, same as $1
    }sx,
    replaced_definitions => qr{
        AS\ (\$[^\$]*\$)        # $1: opening identifier, example: $_$
        ([0-9a-f]{32})          # $2: MD5 checksum
        \1                      # closing identifier, same as $1
    }x
);

my %split;
my $extractor = sub {
    my ($identifier, $definition) = @_;
    my $checksum = md5_hex($definition);
    $split{$checksum} = $definition;
    print "." if $i++ % 10 == 0;
    return "AS ${identifier}${checksum}${identifier}";
};
print "Extracting body parts of functions";
$schema =~ s/$regexes{definitions}/$extractor->($1,$2)/eg;
print "\n";

print "Parsing";
while ($schema =~ s/(      # $1: entire match
        ^                  # start of line
        ([A-Z]+)           # $2: type of command, example: CREATE
        (\ [A-Z,]+)*\s     # $3: eventual extra commands, example: TABLE
        (?:[a-z]+\.)?      # eventual schema, example: public.
        ("?)               # $4: quoted?
        ([a-z0-9_]+)       # $5: name of object, example: users
        \4                 # quoted?
        ([^;']+|'[^']*')*  # object definition, all chars until the first semicolon, allow quoted semicolons
        ;                  # end of definition
    )//mx) {
    my $body = $1;
    my $type = $2 . (defined $3 ? $3 : '');
    my $name = $5;
    $body =~ s/$regexes{replaced_definitions}/"AS ${1}$split{$2}${1}"/eg;
    $type =~ s/ /_/g;
    push @objects, {name => $name, body => $body, type => $type};
    print "." if $i++ % 10 == 0;
}
print "\n";

# Remove comments
$schema =~ s/^--.*//mg;

# Slim whitespace
$schema =~ s/\s+//g;

if ($schema ne '') {
    die "Unable to parse this: $schema";
}

print "Exporting";
my %all_per_name;
my %all_per_type;
my %md5;
my $id = 1;
foreach my $o (@objects) {
    my $name = $o->{name};
    my $body = $o->{body};
    my $type = $o->{type};

    if ($body =~ m/OWNER TO [a-z0-9_]+;$/) {
        # We are not interested in ownership differences
        next;
    }

    $all_per_name{$name} .= $body . "\n";
    $all_per_type{$type} .= $body . "\n";

    my $path = catdir($save_path,'changes');
    unless (-d $path) {
        make_path($path) or die "Unable to create dir $path: $!";
    }

    my $file = ('0' x (6 - length($id))) . "${id}-${name}.sql";
    write_file(catfile($path,$file), $body);

    my $source = catfile('..','..','changes',$file);
    my $link_path = catdir($save_path,'name',$name);
    unless (-d $link_path) {
        make_path($link_path) or die "Unable to create dir $link_path: $!";
    }
    my $link = catfile($link_path,$file);
    symlink $source, $link or die "Unable to create symlink $source -> $link: $!";

    $source = catfile('..','..','..','changes',$file);
    $link_path = catdir($save_path,'type',$type,$name);
    unless (-d $link_path) {
        make_path($link_path) or die "Unable to create dir $link_path: $!";
    }
    $link = catfile($link_path,$file);
    symlink $source, $link or die "Unable to create symlink $source -> $link: $!";

    $id++;
    print "." if $i++ % 10 == 0;
}

my $checksums = '';
foreach my $name ( sort keys %all_per_name ) {
    write_file(catfile($save_path,'name',"${name}.sql"), $all_per_name{$name});
    $checksums .= "MD5 (${name}.sql) = " . md5_hex($all_per_name{$name}) . "\n";
}

foreach my $type ( sort keys %all_per_type ) {
    write_file(catfile($save_path,'type',"${type}.sql"), $all_per_type{$type});
}

print "\n";

print "Writing checksums";
write_file(catfile($save_path,'checksums.txt'), $checksums);
print "\n";
1;
__END__
=pod

=head1 NAME

pg_dump_extractor.pl - description

=head1 USAGE

./pg_dump_extractor.pl <file>

Arguments:

=over 4

=item file - source to parse

output from pg_dump -s command

=back

=cut