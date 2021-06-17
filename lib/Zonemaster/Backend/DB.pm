package Zonemaster::Backend::DB;

our $VERSION = '1.2.0';

use Moose::Role;

use 5.14.2;

use JSON::PP;
use Digest::MD5 qw(md5_hex);
use Encode;
use Log::Any qw( $log );

requires qw(
  add_api_user_to_db
  add_batch_job
  create_new_batch_job
  create_new_test
  from_config
  get_test_history
  get_test_params
  process_unfinished_tests_give_up
  select_unfinished_tests
  test_progress
  test_results
  user_authorized
  user_exists_in_db
);

=head2 get_db_class

Get the database adapter class for the given database type.

Throws and exception if the database adapter class cannot be loaded.

=cut

sub get_db_class {
    my ( $class, $db_type ) = @_;

    my $db_class = "Zonemaster::Backend::DB::$db_type";

    require( "$db_class.pm" =~ s{::}{/}gr );
    $db_class->import();

    return $db_class;
}

sub user_exists {
    my ( $self, $user ) = @_;

    die "username not provided to the method user_exists\n" unless ( $user );

    return $self->user_exists_in_db( $user );
}

sub add_api_user {
    my ( $self, $username, $api_key ) = @_;

    die "username or api_key not provided to the method add_api_user\n"
      unless ( $username && $api_key );

    die "User already exists\n" if ( $self->user_exists( $username ) );

    my $result = $self->add_api_user_to_db( $username, $api_key );

    die "add_api_user_to_db not successful\n" unless ( $result );

    return $result;
}

# Standard SQL, can be here
sub get_test_request {
    my ( $self, $queue_label ) = @_;

    my $result_id;
    my $dbh = $self->dbh;

    my ( $id, $hash_id );
    if ( defined $queue_label ) {
        ( $id, $hash_id ) = $dbh->selectrow_array( qq[ SELECT id, hash_id FROM test_results WHERE progress=0 AND queue=? ORDER BY priority DESC, id ASC LIMIT 1 ], undef, $queue_label );
    }
    else {
        ( $id, $hash_id ) = $dbh->selectrow_array( q[ SELECT id, hash_id FROM test_results WHERE progress=0 ORDER BY priority DESC, id ASC LIMIT 1 ] );
    }

    if ($id) {
        $dbh->do( q[UPDATE test_results SET progress=1 WHERE id=?], undef, $id );
        $result_id = $hash_id;
    }
    return $result_id;
}

# Standatd SQL, can be here
sub get_batch_job_result {
    my ( $self, $batch_id ) = @_;

    my $dbh = $self->dbh;

    my %result;
    $result{nb_running} = 0;
    $result{nb_finished} = 0;

    my $query = "
        SELECT hash_id, progress
        FROM test_results
        WHERE batch_id=?";

    my $sth1 = $dbh->prepare( $query );
    $sth1->execute( $batch_id );
    while ( my $h = $sth1->fetchrow_hashref ) {
        if ( $h->{progress} eq '100' ) {
            $result{nb_finished}++;
            push(@{$result{finished_test_ids}}, $h->{hash_id});
        }
        else {
            $result{nb_running}++;
        }
    }

    return \%result;
}

sub process_unfinished_tests {
    my ( $self, $queue_label, $test_run_timeout, $test_run_max_retries ) = @_;

    my $sth1 = $self->select_unfinished_tests(    #
        $queue_label,
        $test_run_timeout,
        $test_run_max_retries,
    );

    while ( my $h = $sth1->fetchrow_hashref ) {
        if ( $h->{nb_retries} < $test_run_max_retries ) {
            $self->schedule_for_retry($h->{hash_id});
        }
        else {
            my $result;
            if ( defined $h->{results} && $h->{results} =~ /^\[/ ) {
                $result = decode_json( $h->{results} );
            }
            else {
                $result = [];
            }
            push @$result,
              {
                "level"     => "CRITICAL",
                "module"    => "BACKEND_TEST_AGENT",
                "tag"       => "UNABLE_TO_FINISH_TEST",
                "timestamp" => $test_run_timeout,
              };
            $self->process_unfinished_tests_give_up($result, $h->{hash_id});
        }
    }
}

# A thin wrapper around DBI->connect to ensure similar behavior across database
# engines.
sub _new_dbh {
    my ( $class, $data_source_name, $user, $password ) = @_;

    if ( $user ) {
        $log->noticef( "Connecting to database '%s' as user '%s'", $data_source_name, $user );
    }
    else {
        $log->noticef( "Connecting to database '%s'", $data_source_name );
    }

    my $dbh = DBI->connect(
        $data_source_name,
        $user,
        $password,
        {
            RaiseError => 1,
            AutoCommit => 1,
        }
    );

    $dbh->{AutoInactiveDestroy} = 1;

    return $dbh;
}

sub generate_fingerprint {
    my ( $self, $params ) = @_;

    my $js = JSON::PP->new;
    $js->canonical( 1 );

    my $encoded_params = $js->encode( $params );
    my $fingerprint = md5_hex( encode_utf8( $encoded_params ) );

    return ( $fingerprint, $encoded_params );
}

no Moose::Role;

1;
