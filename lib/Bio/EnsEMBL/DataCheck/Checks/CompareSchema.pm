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

package Bio::EnsEMBL::DataCheck::Checks::CompareSchema;

use warnings;
use strict;

use Moose;
use Path::Tiny;
use Test::More;
use Bio::EnsEMBL::DataCheck::Test::DataCheck;
use Bio::EnsEMBL::DataCheck::Utils qw/repo_location/;

extends 'Bio::EnsEMBL::DataCheck::DbCheck';

use constant {
  NAME        => 'CompareSchema',
  DESCRIPTION => 'Compare database schema to definition in SQL file',
  DB_TYPES    => ['cdna', 'core', 'funcgen', 'otherfeatures', 'production', 'rnaseq', 'variation']
};

use Data::Dumper;

sub tests {
  my ($self) = @_;

  my %file_schema;

  my $table_sql_file = $self->table_sql_file();
  my $table_sql = path($table_sql_file)->slurp;

  my @file_tables = $table_sql =~ /(CREATE TABLE[^;]+;)/gms;
  foreach (@file_tables) {
    my ($table_name, $table, $keys) = $self->normalise_table_def($_);
    $file_schema{$table_name} = {'table' => $table, 'keys' => $keys};
  }

  my %db_schema;

  my $helper = $self->dba->dbc->sql_helper();
  my $db_table_names = $helper->execute_simple(-SQL => 'show tables;');

  foreach my $table_name (@$db_table_names) {
    my $sql = "show create table $table_name";
    my $db_table = $helper->execute_into_hash(-SQL => $sql);

    my (undef, $table, $keys) = $self->normalise_table_def($$db_table{$table_name});
    $db_schema{$table_name} = {'table' => $table, 'keys' => $keys};
  }

  # If comparing the file and db hashes fails, run table-by-table.
  # The test stops on the first error, so if there are problems with
  # several tables this avoids an annoying fix/re-run/fix cycle.
  my $desc = "Database schema matches schema defined in file";
  my $pass = is_deeply(\%file_schema, \%db_schema, $desc);
  if (!$pass) {
    foreach my $table_name (sort keys %file_schema) {
      if (exists $db_schema{$table_name}) {
        my $desc_table = "Table definition matches for $table_name";
        is_deeply($file_schema{$table_name}, $db_schema{$table_name}, $desc_table);
      }
    }
  }
}

sub normalise_table_def {
  my ($self, $table) = @_;

  # Remove column/table name quoting.
  $table =~ s/`//gm;

  # Remove whitespace.
  $table =~ s/^\s+//gm;
  $table =~ s/ +/ /gm;
  $table =~ s/, +/,/gm;
  $table =~ s/ +,/,/gm;
  $table =~ s/\( /\(/gm;
  $table =~ s/ \)/\)/gm;
  $table =~ s/\n+/\n/gm;

  # Put ENUMs all on one line.
  $table =~ s/\n('.*)/$1/gm;

  # Capitalise KEY keywords
  $table =~ s/^((?:primary |unique )*key)/\U$1/gm;

  # Normalise case: everything after column name is upper-cased.
  $table =~ s/^([a-z]\w+\s)(.+)/$1\U$2/gm;

  # Remove unnecessary test for existence.
  $table =~ s/ IF NOT EXISTS//gm;

  # Add space after table name
  $table =~ s/(CREATE TABLE \w+)\(/$1 \(/gm;

  # Use standard abbreviation for integer
  $table =~ s/INTEGER/INT/gm;

  # Use standard name for key
  $table =~ s/INDEX/KEY/gm;

  # Add space after KEY keyword
  $table =~ s/KEY(\S)/KEY $1/gm;

  # Remove KEY name
  $table =~ s/(KEY )\w+ */$1/gm;

  # Add space after KEY name
  #$table =~ s/(KEY \S+)\(/$1 \(/gm;

  # Use standard name for tinyint
  $table =~ s/BOOLEAN/TINYINT/gm;

  # Having a number in parentheses after an INT definition is inconsistent.
  # It controls padding with zeroes, and can safely be ignored.
  $table =~ s/INT\(\d+\)/INT/gm;

  # Having default NULL is, er, the default; sometimes it's explicit,
  # other times implicit, so remove it to be consistent.
  $table =~ s/\sDEFAULT NULL//gm;

  # Auto-increment fields are not null by default.
  $table =~ s/NOT NULL AUTO_INCREMENT/AUTO_INCREMENT/gm; 

  # Quote all numeric defaults.
  $table =~ s/(\sDEFAULT )(\d+)/$1'$2'/gm;

  # Ensure default is at the end, which is the standard place for it.
  $table =~ s/(\sDEFAULT '[^']*')([^,]+)/$2$1/gm;

  # Remove comments.
  $table =~ s/#.*//gm;
  $table =~ s/^\-\-.*//gm;

  # Remove things like collation and checksum status.
  $table =~ s/[^\)]+\Z//gm;
  $table =~ s/,\s*\)\Z/\n\)/m;

  # Key order can be variable, so extract into an ordered list.
  my @keys = $table =~ /^((?:PRIMARY |UNIQUE )*KEY.*),*/gm;
  foreach (@keys) {
    $_ =~ s/,$//;
  }
  @keys = sort @keys;

  # Remove keys from table definition since they have been extracted.
  $table =~ s/^((?:PRIMARY |UNIQUE )*KEY\s.*)\n//gm;

  my ($table_name) = $table =~ /CREATE TABLE (\S+)/m;

  return ($table_name, $table, \@keys);
}

sub table_sql_file {
  my ($self) = @_;

  my %repo_names = (
    'cdna'          => 'ensembl',
    'compara'       => 'ensembl-compara',
    'core'          => 'ensembl',
    'funcgen'       => 'ensembl-funcgen',
    'otherfeatures' => 'ensembl',
    'production'    => 'ensembl-production',
    'rnaseq'        => 'ensembl',
    'variation'     => 'ensembl-variation',
  );

  # Don't need checking here, the DB_TYPES ensure we won't get
  # a $dba from a group that we can't handle, and the repo_location
  # method will die if the repo path isn't visible to Perl.
  my $repo_name      = $repo_names{$self->dba->group};
  my $repo_location  = repo_location($repo_name);
  my $table_sql_file = "$repo_location/sql/table.sql";

  if (! -e $table_sql_file) {
    die "Table file does not exist: $table_sql_file";
  }

  return $table_sql_file;
}

1;

