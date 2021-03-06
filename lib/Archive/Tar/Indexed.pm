package Archive::Tar::Indexed;

# allow fast indexed reading of individual files in a tar file as well as fast appending of new files

use strict;

use File::Path;
use File::Temp ();
use Fcntl qw/:flock :seek/;
use POSIX;
use Archive::Tar;
use Cwd;
use Try::Tiny;
use MediaWords::CommonLibs;
use Modern::Perl "2013";
use File::Touch;

sub _dd
{
    my ( $tar_file, $starting_block, $num_blocks ) = @_;

    open my $fh, '<', $tar_file;

    seek( $fh, $starting_block * 512, 0 );

    my $ret;

    my $chars_read = read $fh, $ret, $num_blocks * 512;

    die "Read $chars_read expected " . $num_blocks * 512 . ":$!" unless $chars_read = $num_blocks * 512;

    close( $fh );

    return $ret;
}

sub _get_content_from_tar_pp
{
    my ( $tar_file, $file_name, $starting_block, $num_blocks ) = @_;

    my $dd_cmd = "dd if='$tar_file' bs=512 skip=$starting_block count=$num_blocks 2> /dev/null ";

    #    my $tar_content = `$dd_cmd`;

    my $tar_content = _dd( $tar_file, $starting_block, $num_blocks );

    open my $tar_fh, "<", \$tar_content;

    my $tar = Archive::Tar->new( $tar_fh );

    die "Error creating Archive::Tar: $@" unless $tar;

    my $content = $tar->get_content( $file_name );

    return $content;
}

# read the given file from the given tar file at the given starting block with the given number of blocks
# return a ref to the file contents.
sub read_file
{
    my ( $tar_file, $file_name, $starting_block, $num_blocks ) = @_;

    warn( "number of blocks cannot be 0. Tar file '$tar_file', file name '$file_name' " ) if $num_blocks == 0;

    my $content = _get_content_from_tar_pp( $tar_file, $file_name, $starting_block, $num_blocks );

    if ( $content eq '' )
    {
        warn(
"Unable to retrieve content from tar for archive $tar_file and $file_name with blocks $starting_block + $num_blocks "
        );
    }

    return \$content;
}

# get the lock file for a given archive. if the directory that contains the file does not exist, create it.
sub _get_lock_file
{
    my ( $tar_file ) = @_;

    my $pos_file = File::Spec->tmpdir . "/$tar_file";

    my $pos_dir = $pos_file;

    $pos_dir =~ s~/[^/]*$~~;

    File::Path::mkpath( $pos_dir );

    return $pos_file;
}

# if there's no position file, find the starting block to
# append to (the block after the last block of the last file).
#
# this is necessary because tar sticks a variable number of null
# blocks at the end of every tar archive, and we need to put the new
# archive right after the last valid block.  We find the last valid block
# seeking to the end of the file (or the given position), reading the block, testing whether it
# is a null block, moving back one block if it is not, and so on
# until we find a non-null block.
sub _find_starting_block
{
    my ( $tar_file ) = @_;

    if ( !-f $tar_file )
    {
        return 0;
    }

    my $tar_size = ( stat( $tar_file ) )[ 7 ];

    if ( !open( TAR, $tar_file ) )
    {
        die( "unable to open tar file: $!" );
    }

    my $pos = $tar_size;
    while ( $pos > 0 )
    {
        seek( TAR, $pos - 512, SEEK_SET );
        my $block;
        if ( !read( TAR, $block, 512 ) )
        {
            die( "Unable to read from tar file: $!" );
        }
        if ( $block =~ /[^\0]/o )
        {
            last;
        }
        else
        {
            $pos -= 512;
        }
    }

    return POSIX::ceil( $pos / 512 );
}

# return the name of the file at the given block_position in the archive.
# starting at pos, get the number of blocks in the current archive by
# counting up to the first null bock and then to the first non-null block.
# this is helpful for restoring an archive that has been corrupted somehow.
sub get_file_stats
{
    my ( $archive_file, $starting_block_pos ) = @_;

    my $total_blocks = ( stat( $archive_file ) )[ 7 ] / 512;

    return () if ( $starting_block_pos >= $total_blocks );

    my $block_pos = $starting_block_pos;

    open( ARCHIVE, $archive_file ) || die( "unable to open archive file '$archive_file': $!" );

    # find next null block
    while ( $block_pos < $total_blocks )
    {
        my $buffer;
        seek( ARCHIVE, $block_pos * 512, SEEK_SET ) || die( "Unable to seek to block $block_pos in file $archive_file: $!" );
        read( ARCHIVE, $buffer, 512 ) || die( "Unable to read block $block_pos in file $archive_file: $!" );

        if ( $buffer =~ /^([0-9]+\/)+[0-9]+.gz/ )
        {
            my $tar_cmd  = "dd if='$archive_file' bs=512 skip=$block_pos count=1 2> /dev/null | tar -t -f - 2> /dev/null";
            my $tar_list = `$tar_cmd`;

            my ( $file_path ) = split( "\n", $tar_list );

            if ( $file_path )
            {
                close( ARCHIVE );
                return ( $file_path, $block_pos );
            }
        }

        $block_pos++;
    }

    close( ARCHIVE );
    return ();
}

# append the given file contents to the given tar file under the given path.
# returns the starting block and number of blocks for the file, to be passed
# into read_file.
sub append_file
{
    my ( $tar_file, $file_contents_ref, $file_name ) = @_;

    if ( $tar_file =~ /[^a-zA-Z0-9_\-]$/ )
    {
        die( "Only [A-Za-z0-9_\-] allowed with tar file name" );
    }

    my $temp_dir = File::Temp::tempdir || die( "Unable to create temp dir" );

    my $file_path = $file_name;
    $file_path =~ s~([^/]+)$~~;

    File::Path::mkpath( "$temp_dir/$file_path" );

    if ( !open( FILE, "> $temp_dir/$file_name" ) )
    {
        File::Path::rmtree( $temp_dir );
        die( "Unable to open file '$temp_dir/$file_name': $!" );
    }

    if ( !( print FILE ${ $file_contents_ref } ) )
    {
        die( "Unable to write to file '$temp_dir/$file_name': $!" );
    }

    close( FILE );

    my $lock_file = _get_lock_file( $tar_file );

    if ( !open( LOCK_FILE, '>', $lock_file ) )
    {
        File::Path::rmtree( $temp_dir );
        die( "Unable to open lock file '$lock_file': $!" );
    }

    flock( LOCK_FILE, LOCK_EX );

    if ( !( -x $tar_file ) )
    {
        touch( $tar_file );
    }

    my @pre_tar_stats = stat( $tar_file );

    if ( !open( TAR_FILE, '>>', $tar_file ) )
    {
        File::Path::rmtree( $temp_dir );
        die( "Unable to open tar file '$tar_file': $!" );
    }

    ##TODO use Archive::Tar instead of calling tar with backticks

    my $tar_cmd = "tar -c -C '$temp_dir' -f - '$file_name'";

    # the tar command fails very occasionally for some reason
    my $tar_output;
    for my $i ( 0 .. 4 )
    {
        last if ( $tar_output = `$tar_cmd` );
        sleep( 1 );
    }

    #my $old_cwd = getcwd;
    #my $tar_output_new = '';

    # try
    # {
    #     chdir( $temp_dir );
    #     my $tar = Archive::Tar->new;

    #     say "Adding file $file_name ";
    #     $tar->add_files( $file_name );
    #    # open my $fake_tar_file_handle, '>', \$tar_output;

    #     say STDERR "starting write to fake tar file";

    #     #$tar->write( $fake_tar_file_handle );
    #     $tar->write( '/tmp/test_write.tar' );

    #     #close( $fake_tar_file_handle );

    #     #say STDERR "Wrote to tar_output:'$tar_output'";
    #     exit;
    # }
    # catch
    # {
    #     chdir( $old_cwd );
    #     die $_;
    # }
    # finally
    # {
    #     chdir( $old_cwd );
    # };

    warn( "append_file: 0 length tar output ( $tar_cmd )" ) unless ( $tar_output );

    #$tar_output = $tar_output_new;

    if ( !( print TAR_FILE $tar_output ) )
    {
        die( "Unable to write to file '$tar_file': $!" );
    }

    close( TAR_FILE );

    my @post_tar_stats = stat( $tar_file );

    flock( LOCK_FILE, LOCK_UN );
    close( LOCK_FILE );

    File::Path::rmtree( $temp_dir );

    my $tar_file_len   = $post_tar_stats[ 7 ] - $pre_tar_stats[ 7 ];
    my $num_blocks     = $tar_file_len / 512;
    my $starting_block = $pre_tar_stats[ 7 ] / 512;

    ## MAYBE we should die even if the tar command filed
    die "Unexpected zero length output" if ( $num_blocks == 0 ) && ( $tar_cmd );
    return ( $starting_block, $num_blocks );
}

1;
