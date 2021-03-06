=head1 LICENSE
Copyright [2018] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=head1 NAME
Bio::EnsEMBL::DataCheck::Pipeline::RunDataChecks

=head1 DESCRIPTION
A Hive module that runs a set of datachecks.

=cut

package Bio::EnsEMBL::DataCheck::Pipeline::RunDataChecks;

use strict;
use warnings;
use feature 'say';

use Bio::EnsEMBL::DataCheck::Manager;
use Path::Tiny;

use base ('Bio::EnsEMBL::Hive::Process');

sub param_defaults {
  my ($self) = @_;

  my %manager_params = (
    datacheck_dir      => undef,
    index_file         => undef,
    history_file       => undef,
    output_dir         => undef,
    output_filename    => undef,
    overwrite_files    => 1,
    datacheck_names    => [],
    datacheck_patterns => [],
    datacheck_groups   => [],
    datacheck_types    => [],
  );

  my %dbcheck_params = (
    dba            => undef,
    dbname         => undef,
    species        => undef,
    group          => 'core',
    registry_file  => undef,
    server_uri     => undef,
    old_server_uri => undef,
  );

  return {
    %manager_params,
    %dbcheck_params,
    failures_fatal => 1,
  };
}

sub fetch_input {
  my $self = shift;

  my $output_file;
  if ($self->param_is_defined('output_dir') && $self->param_is_defined('output_filename')) {
    $self->param('output_file', $self->param('output_dir') . '/' . $self->param('output_filename') . '.txt');
  }

  my %manager_params;
  $manager_params{datacheck_dir} = $self->param('datacheck_dir') if $self->param_is_defined('datacheck_dir');
  $manager_params{index_file}    = $self->param('index_file')    if $self->param_is_defined('index_file');
  $manager_params{history_file}  = $self->param('history_file')  if $self->param_is_defined('history_file');
  $manager_params{output_file}   = $self->param('output_file')   if $self->param_is_defined('output_file');

  $manager_params{overwrite_files} = $self->param('overwrite_files');

  $manager_params{names}           = $self->param('datacheck_names');
  $manager_params{patterns}        = $self->param('datacheck_patterns');
  $manager_params{groups}          = $self->param('datacheck_groups');
  $manager_params{datacheck_types} = $self->param('datacheck_types');

  my $manager = Bio::EnsEMBL::DataCheck::Manager->new(%manager_params);
  $self->param('manager', $manager);

  my $datacheck_params = $self->datacheck_params();
  $self->param('datacheck_params', $datacheck_params);
}

sub run {
  my $self = shift;

  my $manager          = $self->param_required('manager');
  my $datacheck_params = $self->param_required('datacheck_params');

  my ($datachecks, $aggregator) = $manager->run_checks(%$datacheck_params);

  if ($aggregator->has_errors) {
    my %datachecks = map { $_->name => $_ } @$datachecks;

    my $failed_names = join(", ", $aggregator->failed);
    my $msg = "Datachecks failed: $failed_names";

    foreach my $failed ($aggregator->failed) {
      $msg .= "\n" . $datachecks{$failed}->output;
    }

    if ($self->param_required('failures_fatal')) {
      die $msg;
    } else {
      $self->warning($msg);
    }
  }

  # Force scalar context (and therefore counts) by multiplying by one.
  $self->param('passed',  $aggregator->passed  * 1);
  $self->param('failed',  $aggregator->failed  * 1);
  $self->param('skipped', $aggregator->skipped * 1);

  $self->param('datachecks', $datachecks);
}

sub write_output {
  my $self = shift;

  my $summary = {
    datachecks_passed  => $self->param('passed'),
    datachecks_failed  => $self->param('failed'),
    datachecks_skipped => $self->param('skipped'),
    history_file       => $self->param('history_file'),
    output_file        => $self->param('output_file'),
  };

  $self->dataflow_output_id($summary, 1);

  foreach my $datacheck ( @{$self->param('datachecks')} ) { 
    my $output = {
      datacheck_name   => $datacheck->name,
      datacheck_params => $self->param('datacheck_params'),
      datacheck_output => $datacheck->output,
    };

    if ($datacheck->_passed) {
      $self->dataflow_output_id($output, 3);
    } else {
      $self->dataflow_output_id($output, 4);
    }
  }
}

sub datacheck_params {
  my $self = shift;

  my $datacheck_params = {};

  $self->set_dba_param($datacheck_params);

  $self->set_registry_param($datacheck_params);

  return $datacheck_params;
}

sub set_dba_param {
  my $self = shift;
  my ($params) = @_;

  my $dba     = $self->param('dba');
  my $dbname  = $self->param('dbname');
  my $species = $self->param('species');
  my $group   = $self->param('group');

  my $dba_species_only = 0;

  unless (defined $dba) {
    if (defined $dbname) {
      my $dbas = Bio::EnsEMBL::Registry->get_all_DBAdaptors_by_dbname($dbname);
      if (scalar(@$dbas) == 1) {
        $dba = $$dbas[0];
      } elsif (scalar(@$dbas) == 0) {
        $self->throw("No databases matching '$dbname' in registry");
      } elsif (scalar(@$dbas) > 1) {
        # This seems like a fragile way to detect a multispecies database,
        # but it's how the registry does it...
        if ($dbname =~ /_collection_/) {
          # The get_all_DBAdaptors_by_dbname method gives us a DBA for
          # each species in the collection. Which is nice, but not what
          # we want. The datacheck code will take of species-specific
          # stuff, if necessary.
          $dba = $$dbas[0];
        } else {
          $self->throw("Multiple databases matching '$dbname' in registry");
        }
      }
    } elsif (defined $species && defined $group) {
      $dba = Bio::EnsEMBL::Registry->get_DBAdaptor($species, $group);
      if (defined $dba) {
        $dba_species_only = 1;
      } else {
        $self->throw("No $group database for $species in registry");
      }
    } elsif (defined $species) {
      $self->throw("Missing database group for $species");
    }
  }

  if (defined $dba) {
    $$params{dba} = $dba;
    $$params{dba_species_only} = $dba_species_only;
  }

  # Note that it's not an error to not define $dba; it's not a mandatory
  # parameter for datachecks, because databases aren't necessarily needed.
}

sub set_registry_param {
  my $self = shift;
  my ($params) = @_;

  my $registry_file  = $self->param('registry_file');
  my $server_uri     = $self->param('server_uri');
  my $old_server_uri = $self->param('old_server_uri');

  $$params{registry_file}  = $registry_file  if defined $registry_file;
  $$params{server_uri}     = $server_uri     if defined $server_uri;
  $$params{old_server_uri} = $old_server_uri if defined $old_server_uri;
}

1;
