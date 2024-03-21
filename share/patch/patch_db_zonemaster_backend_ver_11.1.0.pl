use strict;
use warnings;

use List::MoreUtils qw(zip_unflatten);
use JSON::PP;
use Try::Tiny;

use Zonemaster::Backend::Config;
use Zonemaster::Engine;

my $config = Zonemaster::Backend::Config->load_config();

my %module_mapping;
for my $module ( Zonemaster::Engine->modules ) {
    $module_mapping{lc $module} = $module;
}

my %patch = (
    mysql       => \&patch_db_mysql,
    postgresql  => \&patch_db_postgresql,
    sqlite      => \&patch_db_sqlite,
);

my $db_engine = $config->DB_engine;
print "Configured database engine: $db_engine\n";

if ( $db_engine =~ /^(MySQL|PostgreSQL|SQLite)$/ ) {
    print( "Starting database migration\n" );
    $patch{ lc $db_engine }();
    print( "\nMigration done\n" );
}
else {
    die "Unknown database engine configured: $db_engine\n";
}

# depending on the resources available to select all data in database
# update $row_count to your needs
sub _update_data_result_entries {
    my ( $dbh, $row_count ) = @_;

    my $json = JSON::PP->new->allow_blessed->convert_blessed->canonical;

    # update only jobs with results
    my ( $row_total ) = $dbh->selectrow_array( 'SELECT count(*) FROM test_results WHERE results IS NOT NULL' );
    print "Will update $row_total rows\n";

    my %levels = Zonemaster::Engine::Logger::Entry->levels();

    my $row_done = 0;
    while ( $row_done < $row_total ) {
        print "Progress update: $row_done / $row_total\n";
        my $row_updated = 0;
        my $sth1 = $dbh->prepare( 'SELECT hash_id, results FROM test_results WHERE results IS NOT NULL ORDER BY id ASC LIMIT ? OFFSET ?' );
        $sth1->execute( $row_count, $row_done );
        while ( my $row = $sth1->fetchrow_arrayref ) {
            my ( $hash_id, $results ) = @$row;

            next unless $results;

            my @records;
            my $entries = $json->decode( $results );

            foreach my $m ( @$entries ) {
                my $module = $module_mapping{ lc $m->{module} } // ucfirst lc $m->{module};
                my $testcase =
                  ( !defined $m->{testcase} or $m->{testcase} eq 'UNSPECIFIED' )
                  ? 'Unspecified'
                  : $m->{testcase} =~ s/[a-z_]*/$module/ir;

                if ($testcase eq 'Delegation01' and $m->{tag} =~ /^(NOT_)?ENOUGH_IPV[46]_NS_(CHILD|DEL)$/) {
                    my @ips = split( /;/, delete $m->{args}{ns_ip_list} );
                    my @names = split( /;/, delete $m->{args}{nsname_list} );
                    my @ns_list = map { join( '/', @$_ ) } zip_unflatten(@names, @ips);
                    $m->{args}{ns_list} = join( ';', @ns_list );
                }

                my $r = [
                    $hash_id,
                    $levels{ $m->{level} },
                    $module,
                    $testcase,
                    $m->{tag},
                    $m->{timestamp},
                    $json->encode( $m->{args} // {} ),
                ];

                push @records, $r;
            }

            my $query_values = join ", ", ("(?, ?, ?, ?, ?, ?, ?)") x @records;
            my $query = "INSERT INTO result_entries (hash_id, level, module, testcase, tag, timestamp, args) VALUES $query_values";
            my $sth = $dbh->prepare( $query );
            $sth = $sth->execute( map { @$_ } @records );

            $row_updated += $dbh->do( "UPDATE test_results SET results = NULL WHERE hash_id = ?", undef, $hash_id );
        }

        # increase by min(row_updated, row_count)
        $row_done += ( $row_updated < $row_count ) ? $row_updated : $row_count;
    }
    print "Progress update: $row_done / $row_total\n";
}

sub _update_data_normalize_domains {
    my ( $db ) = @_;

    my ( $row_total ) = $db->dbh->selectrow_array( 'SELECT count(*) FROM test_results' );
    print "Will update $row_total rows\n";


    my $sth1 = $db->dbh->prepare( 'SELECT hash_id, params FROM test_results' );
    $sth1->execute;

    my $row_done = 0;
    my $progress = 0;

    while ( my $row = $sth1->fetchrow_hashref ) {
        my $hash_id = $row->{hash_id};
        eval {
            my $raw_params = decode_json($row->{params});
            my $domain = $raw_params->{domain};

            # This has never been cleaned
            delete $raw_params->{user_ip};

            my $params = $db->encode_params( $raw_params );
            my $fingerprint = $db->generate_fingerprint( $raw_params );

            $domain = Zonemaster::Backend::DB::_normalize_domain( $domain );

            $db->dbh->do('UPDATE test_results SET domain = ?, params = ?, fingerprint = ? where hash_id = ?', undef, $domain, $params, $fingerprint, $hash_id);
        };
        if ($@) {
            warn "Caught error while updating record with hash id $hash_id, ignoring: $@\n";
        }
        $row_done += 1;
        my $new_progress = int(($row_done / $row_total) * 100);
        if ( $new_progress != $progress ) {
            $progress = $new_progress;
            print("$progress%\n");
        }
    }
}

sub patch_db_mysql {
    use Zonemaster::Backend::DB::MySQL;

    my $db = Zonemaster::Backend::DB::MySQL->from_config( $config );
    my $dbh = $db->dbh;

    $dbh->{AutoCommit} = 0;

    try {
        $db->create_schema();

        print( "\n-> (1/2) Populating new result_entries table\n" );
        _update_data_result_entries( $dbh, 50000 );

        print( "\n-> (2/2) Normalizing domain names\n" );
        _update_data_normalize_domains( $db );

        $dbh->commit();
    } catch {
        print( "Could not upgrade database:  " . $_ );

        $dbh->rollback();
    };
}

sub _patch_db_postgresql_step1 {
    my ($dbh) = @_;

    # Why a cursor instead of a plain SELECT statement? Because DBD::Pg does
    # not use server-side cursors itself when reading the result of a SELECT
    # query.
    #
    # And why is that a problem? That’s because the DBMS will try to compute
    # the entire result set before handing it to the client. With large
    # Zonemaster setups with years of history and millions of tests, this
    # SELECT statement will generate hundreds of millions of rows. So without
    # the appropriate precautions, a plain SELECT query like this one will
    # definitely take out the machine it is running on!
    print("Starting up\n");
    $dbh->do(q[
        DECLARE curs NO SCROLL CURSOR WITH HOLD FOR
        SELECT
          test_results.hash_id,
          log_level.value AS level,
          CASE res->>'module'
            WHEN 'DNSSEC' THEN res->>'module'
            ELSE initcap(res->>'module')
          END AS module,
          CASE
            WHEN res->>'testcase' IS NULL THEN ''
            WHEN res->>'testcase' LIKE 'DNSSEC%' THEN res->>'testcase'
            ELSE initcap(res->>'testcase')
          END AS testcase,
          res->>'tag' AS tag,
          (res->>'timestamp')::real AS timestamp,
          COALESCE(res->'args', '{}') AS args
          FROM test_results,
               json_array_elements(results) as res
          LEFT JOIN log_level ON (res->>'level' = log_level.level)]);

    my $read_sth = $dbh->prepare(q[FETCH FORWARD 10000 FROM curs;]);

    my $write_sth = $dbh->prepare(q[
        INSERT INTO result_entries (hash_id, level, module, testcase, tag, timestamp, args)
        VALUES (?, ?, ?, ?, ?, ?, ?)]
    );

    my $row_inserted = 0;

    while ($read_sth->execute(), $read_sth->rows() > 0) {
        print("Progress update: ${row_inserted} rows inserted\n");
        while (my $row = $read_sth->fetchrow_arrayref) {
            $write_sth->execute(@$row);
        }

        $row_inserted += $read_sth->rows();
    }
}

sub patch_db_postgresql {
    use Zonemaster::Backend::DB::PostgreSQL;

    my $db = Zonemaster::Backend::DB::PostgreSQL->from_config( $config );
    my $dbh = $db->dbh;

    $dbh->{AutoCommit} = 0;

    try {
        $db->create_schema();

        print( "\n-> (1/3) Populating new result_entries table\n" );
        _patch_db_postgresql_step1( $dbh );

        $dbh->do(
            'UPDATE test_results SET results = NULL WHERE results IS NOT NULL'
        );

        print( "\n-> (2/3) Normalizing domain names\n" );
        _update_data_normalize_domains( $db );

        print( "\n-> (3/3) Migrating arguments to messages for Delegation01" );
        $dbh->do(q[
            UPDATE result_entries
               SET args = (
                  SELECT args
                         - ARRAY['ns_ip_list', 'nsname_list']
                         || jsonb_build_object('ns_list', string_agg(name || '/' || ip, ';'))
                    FROM unnest(
                           string_to_array(args->>'ns_ip_list', ';'),
                           string_to_array(args->>'nsname_list', ';'))
                      AS unnest(ip, name))
             WHERE testcase = 'Delegation01'
                   AND tag ~ '^(NOT_)?ENOUGH_IPV[46]_NS_(CHILD|DEL)$'
                   AND (NOT args ? 'ns_list');
        ]);

        $dbh->commit();
    } catch {
        print( "Could not upgrade database:  " . $_ );

        $dbh->rollback();
    };
}

sub patch_db_sqlite {
    use Zonemaster::Backend::DB::SQLite;

    my $db = Zonemaster::Backend::DB::SQLite->from_config( $config );
    my $dbh = $db->dbh;

    $dbh->{AutoCommit} = 0;

    try {
        $db->create_schema();

        print( "\n-> (1/2) Populating new result_entries table\n" );
        _update_data_result_entries( $dbh, 142 );

        print( "\n-> (2/2) Normalizing domain names\n" );
        _update_data_normalize_domains( $db );

        $dbh->commit();
    } catch {
        print( "Error while upgrading database:  " . $_ );

        $dbh->rollback();
    };
}
