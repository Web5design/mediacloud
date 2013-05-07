#!/usr/bin/env perl

# test MediaWords::Crawler::Extractor against manually extracted downloads

use strict;
use warnings;

BEGIN
{
    use FindBin;
    use lib "$FindBin::Bin/../lib";
}

# use HTML::Strip;
use MediaWords::DB;
use Modern::Perl "2012";
use MediaWords::CommonLibs;
use MediaWords::DBI::Downloads;
use Readonly;

#use List::Util qw(first max maxstr min minstr reduce shuffle sum);
#use List::Compare::Functional qw (get_unique get_complement get_union_ref );
#
use Data::Dumper;
use Cwd;

#use Thread::Pool;
use 5.14.2;
use threads;
use Thread::Queue;
use Getopt::Long;

my $_re_generate_cache = 0;
my $_test_sentences    = 0;

my $_download_data_load_file;
my $_download_data_store_file;
my $_dont_store_preprocessed_lines;
my $_dump_training_data_csv;

my $db_global;

sub _rewrite_download_list
{
    my ( $dbs, $downloads ) = @_;

    say "Starting to process batch of " . scalar( @{ $downloads } );

    Readonly my $status_update_frequency => 10;

    my $downloads_processed = 0;

    foreach my $download ( @{ $downloads } )
    {

        #say "rewriting download " . $download->{ downloads_id };
        #say "Old download path: " . $download->{ path };
        MediaWords::DBI::Downloads::rewrite_downloads_content( $dbs, $download );

        #say "New download path: " . $download->{ path };

        $downloads_processed++;

        if ( $downloads_processed % $status_update_frequency == 0 )
        {
            say "Processed $downloads_processed of " . scalar( @{ $downloads } ) . " downloads";
        }
    }

    return;
}

# do a test run of the text extractor
sub main
{

    my $dbs = MediaWords::DB::connect_to_db();

    my $file;
    my $download_ids = [];

    GetOptions(
        'file|f=s'      => \$file,
        'downloads|d=s' => $download_ids,
    ) or die;

    die unless $file || $download_ids;

    my $downloads;

    if ( @{ $download_ids } )
    {
        $downloads =
          $dbs->query( "SELECT * from downloads where  state = 'success' and path like 'content/%' and downloads_id in (??)",
            @$download_ids )->hashes;
    }
    elsif ( $file )
    {
        open( DOWNLOAD_ID_FILE, $file ) || die( "Could not open file: $file" );
        $download_ids = [ <DOWNLOAD_ID_FILE> ];
        $downloads = $dbs->query( "SELECT * from downloads where downloads_id in (??)", @$download_ids )->hashes;
    }

    _rewrite_download_list( $dbs, $downloads );
}

main();