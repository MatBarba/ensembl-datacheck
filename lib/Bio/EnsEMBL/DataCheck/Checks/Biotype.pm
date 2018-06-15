=head1 LICENSE

Copyright [2018] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the 'License');
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an 'AS IS' BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

package Bio::EnsEMBL::DataCheck::Checks::Biotype;

use warnings;
use strict;
use feature 'say';

use Moose;
use Test::More;
use Bio::EnsEMBL::DataCheck::Test::DataCheck;

extends 'Bio::EnsEMBL::DataCheck::DbCheck';

use constant {
  NAME        => 'Biotype',
  DESCRIPTION => 'Check the biotype table',
  GROUPS      => ['EGCoreHandover'],
  DB_TYPES    => ['core']
};

sub tests {
  my ($self) = @_;
 
  my $desc = "Biotype table exists";
  my $db_name = $self->dba->dbc->dbname;
  say $db_name;
  my $table_name = "biotype";
  my $sql = qq/
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = '$db_name' AND table_name = '$table_name'
  /;
  my $table_exists = is_rows_nonzero($self->dba, $sql, $desc);
  
  SKIP : {
    
    skip "because biotype table doesn't exist", 1 unless $table_exists;
    
    my $desc_2 = 'Biotype table is not empty';
    my $sql_2  = q/
    SELECT COUNT(*) FROM biotype;
    /;
    is_rows_nonzero($self->dba, $sql_2, $desc_2);
  }
}

1;

