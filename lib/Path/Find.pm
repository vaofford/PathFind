# ABSTRACT: Simple wrapper module for VRTrack and DBI. Used for connecting to pathogen tracking databases.

=head1 NAME
Path::Find


=head1 SYNOPSIS

@databases = Path::Find->pathogen_databases;
$database  = shift @databases;
my ( $pathtrack, $dbh, $root ) = Path::Find->get_db_info($database);

=cut


use lib "/software/pathogen/internal/pathdev/vr-codebase/modules";

package Path::Find;
use DBI;
use VRTrack::VRTrack;

use File::Slurp;
use YAML::XS;
use Moose;

has 'connection'  => ( is => 'ro', isa => 'HashRef',  lazy_build => 1,   required => 0 );
has 'db_root'     => ( is => 'ro', isa => 'Str',      default => '/lustre/scratch108/pathogen/pathpipe', required => 0 );
has 'db_sub'      => ( is => 'ro', isa => 'HashRef',  lazy_build => 1,   required => 0 );
has 'template'    => ( is => 'ro', isa => 'Str',      default => "genus:species-subspecies:TRACKING:projectssid:sample:technology:library:lane", required => 0 );
has 'environment' => ( is => 'ro', isa => 'Str',      default => 'prod', required => 0 );

sub _build_connection {
  my $self = shift;
  my $e = $self->environment;

  my $config_dir = "/software/pathogen/projects/PathFind/config";

  my %connect = %{ Load( scalar read_file("$config_dir/$e.yml") ) };

  return \%connect;
}

sub _build_db_sub {
  my $self = shift;
  my %dbsub   = ('pathogen_virus_track'  => 'viruses',
               'pathogen_prok_track'     => 'prokaryotes',
               'pathogen_euk_track'      => 'eukaryotes',
               'pathogen_helminth_track' => 'helminths',
               'pathogen_rnd_track'      => 'rnd');
  return \%dbsub;
}

=begin nd

  Method: pathogen_databases
    
  Description:
    Returns list of pathogen databases. Schema is verified by VRTrackFactory.

  Arguments:
    None

  Example:
    my @databases = Path::Find->pathogen_databases;

  Returns:
    Array of database names.

=cut

sub pathogen_databases
{
    my ($self) = @_;

    my %CONNECT = %{ $self->connection };

    my $dbi_t = DBI->data_sources("mysql", \%CONNECT);

    my @db_list_all = grep(s/^DBI:mysql://, DBI->data_sources("mysql", \%CONNECT));


    my @db_list = (); # tracking and external databases
    if($self->environment eq 'prod'){
      push @db_list, grep (/^pathogen_.+_track$/,   @db_list_all); # pathogens_..._track
      push @db_list, grep (/^pathogen_.+_external$/,@db_list_all); # pathogens_..._external

      @db_list = @{$self->_move_production_databases_to_the_front(\@db_list)};
    }
    elsif($self->environment eq 'test'){
      push @db_list, grep (/^pathogen_test_pathfind$/, @db_list_all);
    }

    my @db_list_out = (); # databases with files on disk
    for my $database (@db_list)
    {
        my $root_dir = $self->hierarchy_root_dir($database);
        push @db_list_out, $database  if defined $root_dir;
    }

    return @db_list_out;
}

# Ensure that our largest production databases are searched first
sub _move_production_databases_to_the_front
{
   my ($self,$db_list) = @_;
   my @reordered_db_list;
   my %db_list_lookup = map { $_ => 1 } @{$db_list};

   for my $db_name (qw(pathogen_pacbio_track pathogen_prok_track pathogen_euk_track pathogen_virus_track pathogen_helminth_track))   
   {
     if($db_list_lookup{$db_name})
     {
       push(@reordered_db_list, $db_name);
       delete($db_list_lookup{$db_name});
     }
   }

   for my $db_name (sort keys %db_list_lookup)
   {
     push(@reordered_db_list, $db_name);
   }
   return \@reordered_db_list;
}


=begin nd

  Method: hierarchy_root_dir
    
  Description:
    Returns the root directory for a tracking database.

  Arguments:
    Arg [1] - database name

  Example:
    my $root_dir = Path::Find->hierarchy_root_dir($database);

  Returns:
    Database root directory or undef if directory doesn't exist.

=cut

sub hierarchy_root_dir
{
    my ($self, $database) = @_;
    my %DB_SUB = %{ $self->db_sub };
    my $DB_ROOT = $self->db_root;

    my $sub_dir = exists $DB_SUB{$database} ? $DB_SUB{$database}:$database;
    my $root_dir = "$DB_ROOT/$sub_dir/seq-pipelines";

    return -d $root_dir ? $root_dir : undef;
}

sub lookup_tracking_name_from_database
{
   my ($self, $database) = @_;
   my %DB_SUB = %{ $self->db_sub };
   exists $DB_SUB{$database} ? $DB_SUB{$database}:$database;
}

=begin nd

  Method: hierarchy_template

  Description:
    Returns hierarchy template for pathogen tracking database.

  Arguments:
    None

  Example:
    my $hierarchy_template = Path::Find->hierarchy_template;

  Returns:
    String value.

=cut

sub hierarchy_template
{
    my ($self) = @_;
    return $self->template;
}

=begin nd

  Method: instantiate_vrtrack

  Description:
    Instantiates a VRTrack object for a pathogen database. Returns undef on error.

  Arguments:
    Arg [1] - database name

  Example:
    my $vrtrack = Path::Find->instantiate_vrtrack($database)

  Returns:
    A VRTrack object.

=cut

sub vrtrack
{
    my ($self, $database) = @_;

    return undef unless defined $self->hierarchy_root_dir($database);

    my %connect = %{ $self->connection };
    $connect{database} = $database;
    my $vrtrack = VRTrack::VRTrack->new(\%connect);

    return $vrtrack;
}

=begin nd

  Method: instantiate_dbi($database)

    
  Description:
    Instantiates a DBI object for a pathogen database. Returns undef on error.

  Arguments:
    Arg [1] - database name

  Example:
    my $dbi = Path::Find->instantiate_dbi($database)

  Returns:
    A DBI object.

=cut

sub dbi
{
    my ($self, $database) = @_;

    return undef unless defined $self->hierarchy_root_dir($database);

    my %CONNECT = %{ $self->connection };

    my $dbi_connect = "DBI:mysql:dbname=".$database.";host=".$CONNECT{host}.";port=".$CONNECT{port};
    $dbi_connect .= ";password=".$CONNECT{password} if( defined $CONNECT{password} );
    
    my $dbi = DBI->connect($dbi_connect, $CONNECT{user}) or return undef;

    return $dbi;
}

sub get_db_info{
	my ($self, $db) = @_;

	my $vr = $self->vrtrack($db) or die "Failed to create VRTrack object for '$db'\n";
	my $dbh = $self->dbi($db) or die "Failed to create DBI object for '$db'\n";
	my $root = $self->hierarchy_root_dir($db) or die "Failed to find root directory for '$db'\n";
	return ($vr, $dbh, $root);
}

__PACKAGE__->meta->make_immutable;
no Moose;
1;
