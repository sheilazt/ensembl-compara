
=pod 

=head1 NAME

Bio::EnsEMBL::Compara::RunnableDB::LoadOneGenomeDB

=head1 SYNOPSIS

        # load a genome_db given a class/keyvalue locator (genome_db_id will be generated)
    standaloneJob.pl LoadOneGenomeDB.pm -compara_db "mysql://ensadmin:${ENSADMIN_PSW}@compara2/lg4_test_load1genome" \
        -locator 'Bio::EnsEMBL::DBSQL::DBAdaptor/host=ens-staging;port=3306;user=ensro;pass=;dbname=homo_sapiens_core_64_37;species=homo_sapiens;species_id=1;disconnect_when_inactive=1'

        # load a genome_db given a url-style locator
    standaloneJob.pl LoadOneGenomeDB.pm -compara_db "mysql://ensadmin:${ENSADMIN_PSW}@compara2/lg4_test_load1genome" \
        -locator "mysql://ensro@ens-staging2/mus_musculus_core_64_37"

        # load a genome_db given a reg_conf and species_name as locator
    standaloneJob.pl LoadOneGenomeDB.pm -compara_db "mysql://ensadmin:${ENSADMIN_PSW}@compara2/lg4_test_load1genome" \
        -reg_conf $ENSEMBL_CVS_ROOT_DIR/ensembl-compara/scripts/examples/ensembldb_reg.conf \
        -locator 'mus_musculus'

        # load a genome_db given a reg_conf and species_name as locator with a specific genome_db_id
    standaloneJob.pl LoadOneGenomeDB.pm -compara_db "mysql://ensadmin:${ENSADMIN_PSW}@compara2/lg4_test_load1genome" \
        -reg_conf $ENSEMBL_CVS_ROOT_DIR/ensembl-compara/scripts/pipeline/production_reg_conf.pl \
        -locator 'homo_sapiens' -genome_db_id 90

=head1 DESCRIPTION

This Runnable loads one entry into 'genome_db' table and passes on the genome_db_id.

The format of the input_id follows the format of a Perl hash reference.
Examples:
    { 'species_name' => 'Homo sapiens', 'assembly_name' => 'GRCh37' }
    { 'species_name' => 'Mus musculus' }

supported keys:
    'locator'       => <string>
        one of the ways to specify the connection parameters to the core database (overrides 'species_name' and 'assembly_name')

    'registry_dbs'  => <list_of_dbconn_hashes>
        another, simple way to specify the genome_db (and let the registry search across multiple mysql instances to do the rest)
    'species_name'  => <string>
        mandatory, but what would you expect?

    'first_found'   => <0|1>
        optional, defaults to 0.
        Defines whether we emulate (to a certain extent) the behaviour of load_registry_from_multiple_dbs
        or try the last one that still fits (this would allow to try ens-staging[12] *first*, and only then check if ens-livemirror has is a suitable copy).

    'assembly_name' => <string>
        optional: in most cases it should be possible to find the species just by using 'species_name'

    'genome_db_id'  => <integer>
        optional, in case you want to specify it (otherwise it will be generated by the adaptor when storing)

    'pseudo_stableID_prefix' => <string>
        optional?, see 'GenomeLoadMembers.pm', 'GenomeLoadReuseMembers.pm', 'GeneStoreNCMembers.pm', 'GenomePrepareNCMembers.pm'

    'ensembl_genomes' => <0|1>
        optional, sets the preferential order of precedence of species_name sources, depending on whether the module is run by EG or Compara

    'db_version'    => <integer>
        optional, sets the prefered version of the core databases to load from

=cut

package Bio::EnsEMBL::Compara::RunnableDB::LoadOneGenomeDB;

use strict;
use Bio::EnsEMBL::Registry;
use Bio::EnsEMBL::DBLoader;
use Bio::EnsEMBL::Compara::GenomeDB;
use Bio::EnsEMBL::Compara::GenomeMF;

use base ('Bio::EnsEMBL::Compara::RunnableDB::BaseRunnable');

my $suffix_separator = '__cut_here__';

sub fetch_input {
    my $self = shift @_;

    my $assembly_name = $self->param('assembly_name');
    my $core_dba;

    if(my $locator = $self->param('locator') ) {   # use the locator and skip the registry

        eval {
            $core_dba = Bio::EnsEMBL::DBLoader->new($locator);
        };

        unless($core_dba) {     # assume this is a hive-type locator and try more tricks:
            my $dbc = $self->go_figure_dbc( $locator, 'core' )
                or die "Could not connect to '$locator' as DBC";

            $core_dba = Bio::EnsEMBL::DBSQL::DBAdaptor->new( -DBCONN => $dbc );

            $self->param('locator', $core_dba->locator() );  # substitute the given locator by one in conventional format
        }

    } elsif( $self->param('species_name') ) {    # perform our tricky multiregistry search: find the last one still suitable

        my $genebuild = $self->param('genebuild');

        foreach my $this_core_dba (@{$self->iterate_through_registered_species}) {

            my $this_assembly = $this_core_dba->extract_assembly_name();
            my $this_start_date = $this_core_dba->get_MetaContainer->get_genebuild();

            $genebuild ||= $this_start_date;
            $assembly_name ||= $this_assembly;

            if($this_assembly eq $assembly_name && $this_start_date eq $genebuild) {
                $core_dba = $this_core_dba;

                if($self->param('first_found')) {
                    last;
                }
            } else {
                warn "Found assembly '$this_assembly' when looking for '$assembly_name' or '$this_start_date' when looking for '$genebuild'";
            }

        } # try next registry server
    }

    if( $core_dba ) {
        $self->param('core_dba', $core_dba);
        if($assembly_name) {
            $self->param('assembly_name', $assembly_name);
        }
    } else {
        die "Could not find species_name='".$self->param('species_name')."', assembly_name='".$self->param('assembly_name')."' on the servers provided, please investigate";
    }
}

sub run {
    my $self = shift @_;

    my $core_dba            = $self->param('core_dba');
    my $meta_container      = $core_dba->get_MetaContainer;

    my $assembly_name_in_db = $core_dba->extract_assembly_name();
    my $assembly_name       = $self->param('assembly_name') || $assembly_name_in_db;
    if($assembly_name ne $assembly_name_in_db) {
        die "The required assembly_name ('$assembly_name') is different from the one found in the database ('$assembly_name_in_db'), please investigate";
    }

    my $taxon_id_in_db      = $meta_container->get_taxonomy_id();
    my $taxon_id            = $self->param('taxon_id')  || $taxon_id_in_db;
    if($taxon_id != $taxon_id_in_db) {
        die "taxon_id parameter ($taxon_id) is different from the one defined in the database ($taxon_id_in_db), please investigate";
    }

    my $genome_db_id    = $self->param('genome_db_id')      || undef;
    my $genebuild       = $meta_container->get_genebuild()    || '';
    my $genome_name     = $meta_container->get_production_name() or die "Could not fetch production_name, please investigate";
    my $locator         = $self->param('locator') || $core_dba->locator();

    my $genome_db       = Bio::EnsEMBL::Compara::GenomeDB->new();
    $genome_db->dbID( $genome_db_id );
    $genome_db->taxon_id( $taxon_id );
    $genome_db->name( $genome_name );
    $genome_db->assembly( $assembly_name );
    $genome_db->genebuild( $genebuild );
    $genome_db->locator( $locator );

    $self->param('genome_db', $genome_db);
}

sub write_output {      # store the genome_db and dataflow
    my $self = shift;

    my $genome_db               = $self->param('genome_db');

    $self->compara_dba->get_GenomeDBAdaptor->store($genome_db);
    my $genome_db_id            = $genome_db->dbID();

    my $pseudo_stableID_prefix  = $self->param('pseudo_stableID_prefix');

    $self->dataflow_output_id( {
        'genome_db_id' => $genome_db_id,
        ($pseudo_stableID_prefix ? ('pseudo_stableID_prefix' => $pseudo_stableID_prefix) : ())
    }, 1);
}

# ------------------------- non-interface subroutines -----------------------------------

sub iterate_through_registered_species {
    my $self = shift;

    my $registry_dbs = $self->param('registry_dbs');
    my $registry_files = $self->param('registry_files');
    $registry_dbs || $registry_files || die "unless 'locator' is specified, 'registry_dbs' or 'registry_files' become obligatory parameter";

    my @core_dba_list = ();

    for(my $r_ind=0; $r_ind<scalar(@$registry_dbs); $r_ind++) {
        Bio::EnsEMBL::Registry->load_registry_from_db( %{ $registry_dbs->[$r_ind] }, -species_suffix => $suffix_separator.$r_ind, -db_version => $self->param('db_version') );

        my $no_alias_check = 1;
        my $this_core_dba = Bio::EnsEMBL::Registry->get_DBAdaptor($self->param('species_name').$suffix_separator.$r_ind, 'core', $no_alias_check) || next;
        push @core_dba_list, $this_core_dba;
    }

    for(my $r_ind=0; $r_ind<scalar(@$registry_files); $r_ind++) {

        my $reg_content = Bio::EnsEMBL::Compara::GenomeMF->all_from_file( $registry_files->[$r_ind] );
        push @core_dba_list, grep {$_->get_production_name() eq $self->param('species_name')} @$reg_content;
    }

    return \@core_dba_list;
}

sub Bio::EnsEMBL::DBSQL::DBAdaptor::extract_assembly_name {  # with much regret I have to introduce the highly demanded method this way
    my $self = shift @_;

    my ($cs) = @{$self->get_CoordSystemAdaptor->fetch_all()};
    my $assembly_name = $cs->version;

    return $assembly_name;
}

sub Bio::EnsEMBL::DBSQL::DBAdaptor::locator {  # this is another similar hack (to be included or at least offered for inclusion into Core codebase)
    my $self         = shift @_;

    my ($species_safe) = split(/$suffix_separator/, $self->species());  # The suffix was added to attain uniqueness and avoid collision, now we have to chop it off again.

    my $dbc = $self->dbc();

    return sprintf(
          "%s/host=%s;port=%s;user=%s;pass=%s;dbname=%s;species=%s;species_id=%s;disconnect_when_inactive=%d",
          ref($self), $dbc->host(), $dbc->port(), $dbc->username(), $dbc->password(), $dbc->dbname(), $species_safe, $self->species_id, 1,
    );
}

1;

