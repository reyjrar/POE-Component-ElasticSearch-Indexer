package POE::Component::ElasticSearch::Indexer;
# ABSTRACT: POE session to index data to ElasticSearch

use strict;
use warnings;

# VERSION

use Const::Fast;
use Digest::SHA1 qw(sha1_hex);
use Fcntl qw(:flock);
use HTTP::Request;
use JSON::MaybeXS;
use List::Util qw(shuffle);
use Log::Log4perl qw(:easy);
use Path::Tiny;
use POSIX qw(strftime);
use Ref::Util qw(is_ref is_arrayref is_blessed_ref is_hashref is_coderef);
use Time::HiRes qw(time);
use URI;

use POE qw(
    Component::Client::HTTP
    Component::Client::Keepalive
);

=head1 SYNOPSIS

This POE Session is used to index data to an ElasticSearch cluster.

    use POE qw{ Component::ElasticSearch::Indexer };

    my $es_session = POE::Component::ElasticSearch::Indexer->spawn(
        Alias            => 'es',                    # Default
        Timeout          => 10,                      # Default
        FlushInterval    => 30,                      # Default
        FlushSize        => 1_000,                   # Default
        LoggingConfig    => undef,                   # Default
        DefaultIndex     => 'logs-%Y.%m.%d',         # Default
        DefaultType      => 'log',                   # Default
        BatchDir         => '/tmp/es_index_backlog', # Default
        StatsHandler     => undef,                   # Default
        StatsInterval    => 60,                      # Default
    );

    # Index the document using the queue for better performance
    $poe_kernel->post( es => queue => $json_data );


=head1 DESCRIPTION

This module exists to provide event-based Perl programs with a simple way to
index documents into an ElasticSearch cluster.

=head2 spawn()

This method spawns the ElasticSearch indexing L<POE::Session>. It accepts the
following parameters.

=over 4

=item B<Alias>

The alias this session is available to other sessions as.  The default is
B<es>.

=item B<LoggingConfig>

The L<Log::Log4perl> configuration file for the indexer to use.  Defaults to
writing logs to the current directory into the file C<es_indexing.log>.

=item B<Timeout>

Number of seconds for the HTTP transport connect and transport timeouts.
Defaults to B<10> seconds.

=item B<FlushInterval>

Maximum number of seconds which can pass before a flush of the queue is
attempted.  Defaults to B<30> seconds.

=item B<FlushSize>

Once this number of documents is reached, flush the queue regardless of time
since the last flush.  Defaults to B<1,000>.

=item B<DefaultIndex>

A C<strftime> aware index pattern to use if the document is missing an
C<_index> element.  Defaults to B<logs-%Y.%m.%d>.

=item B<DefaultType>

Use this C<_type> attribute if the document is missing one.  Defaults to
B<log>.

=item B<BatchDir>

If the cluster responds with an HTTP failure code, the batch is written to disk
in this directory to be indexed when the cluster is available again.  Defaults
to C</tmp/es_index_backlog>.

=item B<StatsHandler>

A code reference that will be passed a hash reference containing the keys and
values of counters tracked by this component.  Defaults to C<undef>, meaning no
code is run.

=item B<StatsInterval>

Run the C<StatsHandler> every C<StatsInterval> seconds.  Default to B<60>.

=item B<Templates>

If configured, this will ensure the L<Dynamic
Templates|https://www.elastic.co/guide/en/elasticsearch/reference/master/dynamic-templates.html>
specified exist and are up-to-date with your specifications.


    my $idx = POE::Component::ElasticSearch::Indexer->spawn(
            ...
            Templates => {
                base_settings => { template => '*', settings => { 'index.number_of_shards' => 6 } },
            },
    );

=back


=cut

sub spawn {
    my $type = shift;
    my %params = @_;

    # Setup Logging
    my $loggingConfig = exists $params{LoggingConfig} && -f $params{LoggingConfig} ? $params{LoggingConfig}
                      : \q{
                            log4perl.logger = INFO, Sync
                            log4perl.appender.File = Log::Log4perl::Appender::File
                            log4perl.appender.File.layout   = PatternLayout
                            log4perl.appender.File.layout.ConversionPattern = %d [%P] %p - %m%n
                            log4perl.appender.File.filename = es_indexer.log
                            log4perl.appender.File.mode = truncate
                            log4perl.appender.Sync = Log::Log4perl::Appender::Synchronized
                            log4perl.appender.Sync.appender = File
                        };
    Log::Log4perl->init($loggingConfig) unless Log::Log4perl->initialized;

    # Build Configuration
    my %CONFIG = (
        Alias         => 'es',
        Timeout       => 10,
        FlushInterval => 30,
        FlushSize     => 1_000,
        DefaultIndex  => 'logs-%Y.%m.%d',
        DefaultType   => 'log',
        BatchDir      => '/tmp/es_index_backlog',
        %params,
    );
    if( $CONFIG{Templates} ) {
        if( !is_hashref($CONFIG{Templates}) ) {
            ERROR("Recieved invalid parameter for 'Templates' parameter, ignoring it entirely.");
            delete $CONFIG{Templates};
        }
    }

    # Management Session
    POE::Session->create(
        inline_states => {
            _start    => \&_start,
            _child    => \&_child,
            stats     => \&_stats,
            queue     => \&es_queue,
            flush     => \&es_flush,
            batch     => \&es_batch,
            backlog   => \&es_backlog,
            health    => \&es_health,

            # Templates
            get_templates => \&es_get_templates,
            put_template  => \&es_put_template,

            # HTTP Responses
            resp_bulk          => \&resp_bulk,
            resp_get_templates => \&resp_get_templates,
            resp_put_template  => \&resp_get_templates,
            resp_health        => \&resp_health,
        },
        heap => {
            cfg   => \%CONFIG,
            stats => {},
            start => {},
            batch => {},
            pending_templates => $CONFIG{Templates} || {},
            health            => '',
            es_ready          => 0,
        },
    );

    # Connection Pooling
    my $num_servers  = scalar( @{ $CONFIG{servers} } );
    my $num_per_host = 3;
    my $num_open     = $num_servers * $num_per_host;
    my $pool = POE::Component::Client::Keepalive->new(
        keep_alive   => 60,
        max_open     => $num_open,
        max_per_host => $num_per_host,
        timeout      => $CONFIG{Timeout},
    );
    POE::Component::Client::HTTP->spawn(
        Alias             => 'http',
        ConnectionManager => $pool,
        Timeout           => $CONFIG{Timeout} + 1,   # Give ES 1 second to transit
    );
    INFO(sprintf "Spawned an HTTP Pool for %d servers: %d max connections, %d max per host.",
        $num_servers, $num_open, $num_per_host
    );
    return;
}

#------------------------------------------------------------------------#
# ES Functions

sub _start {
    my ($kernel,$heap) = @_[KERNEL,HEAP];

    # Set our alias
    $kernel->alias_set($heap->{Alias});

    # Set the interval / maximum
    my $adjuster = (1 + (int(rand(10))/20));
    $heap->{cfg}{FlushSize}     *= $adjuster;
    $heap->{cfg}{FlushInterval} *= $adjuster;

    # Batch directory
    path($heap->{cfg}{BatchDir})->mkpath;

    # Run through the backlog
    $kernel->delay( backlog => 2 );
    $heap->{backlog_scheduled} = 1;

    # Start the queue flushing
    $heap->{flush_requested} = time + $heap->{cfg}{flush_interval};
    $kernel->delay( flush => $heap->{cfg}{FlushInterval} );
}

sub _child {
    my ($kernel,$heap,$reason,$child) = @_[KERNEL,HEAP,ARG0,ARG1];
    INFO(sprintf "child(%s) event: %s", $child->ID, $reason);
}

sub _stats {
    my ($kernel,$heap) = @_[KERNEL,HEAP,ARG0,ARG1];

    # Reschedule
    $kernel->delay( stats => $heap->{cfg}{StatsInterval} );

    # Extract the stats from the heap
    my $stats = delete $heap->{stats};
    $heap->{stats} = {};

    # Display our stats
    if( is_coderef($heap->{cfg}{StatsHandler}) ) {
        # Run in an eval and remove the handler if the code dies
        eval {
            $heap->{cfg}{StatsHandler}->($stats);
            1;
        } or do {
            my $err = $@;
            ERROR("Disabling the StatsHandler due to fatal error: $!");
            $heap->{stats}{StatsHandler} = undef;
        };
    }
    # Also output at DEBUG level
    DEBUG( "STATS - " .
        scalar(keys %$stats) ? join(', ', map { "$_=$stats->{$_}" } sort keys %$stats )
                             : 'Nothing to report.'
    );
}

=head2 EVENTS

The events provided by this component.

=over 2

=item B<queue>

Takes an array reference of hash references to be transformed into JSON
documents and submitted to the cluster's C<_bulk> API.

Alternatively, you can provide an array reference containg blessed objects that
provide an C<as_bulk()> method.  The result of that method will be added to the
bulk queue.

Example use case:

    sub syslog_handle_line {
        my ($kernel,$heap,$session,$line) = @_[KERNEL,HEAP,SESSION,ARG0];

        # Create a document from syslog data
        local $Parse::Syslog::Line::PruneRaw = 1;
        local $Parse::Syslog::Line::PruneEmpty = 1;
        my $evt = parse_syslog_line($line);

        # Override the type
        $evt->{_type} = 'syslog';

        # If we want to collect this event into an auth index:
        if( exists $Authentication{$evt->{program}} ) {
            $evt->{_index} = strftime('authentication-%Y.%m.%d',
                    localtime($evt->{epoch} || time)
            );
        }
        else {
            # Set an _epoch for the es queue DefaultIndex
            $evt->{_epoch} = $evt->{epoch} ? delete $evt->{epoch} : time;
        }
        # You'll want to batch these in your processor to avoid excess
        # overhead creating so many events in the POE loop
        push @{ $heap->{batch} }, $evt;

        # Once we hit 10 messages, force the flush
        $kernel->call( $session->ID => 'submit_batch') if @{ $heap->{batch} } > 10;
    }

    sub submit_batch {
        my ($kernel,$heap) = @_[KERNEL,HEAP];

        # Reset the batch scheduler
        $kernel->delay( 'submit_batch' => 10 );

        $kernel->post( es => queue => delete $heap->{batch} );
        $heap->{batch} = [];
    }

=for Pod::Coverage es_queue

=cut

sub es_queue {
    my ($kernel,$heap,$data) = @_[KERNEL,HEAP,ARG0];

    return unless $data && is_ref($data);

    my $events = is_arrayref($data) ? $data : [$data];
    foreach my $doc ( @{ $events } ) {
        my $record;
        if( is_blessed_ref($doc) ) {
            eval {
                $record = $doc->as_bulk();
            };
        }
        if( !$record ) {
            # Assemble Metadata
            my $epoch = $doc->{_epoch} ? delete $doc->{_epoch} : time;
            my %meta = (
                _index => $doc->{_index} ? delete $doc->{_index} : strftime($heap->{cfg}{DefaultIndex},localtime($epoch)),
                _type  => $doc->{_type}  ? delete $doc->{_type}  : $heap->{cfg}{DefaultType},
                $doc->{_id} ? ( _id => delete $doc->{_id} ) : (),
            );
            $record = join('', map { "$_\n" }
                encode_json({ index => \%meta }),
                encode_json($doc)
            );
        }
        $heap->{queue} = [] unless exists $heap->{queue};
        push @{ $heap->{queue} }, $record;
    }

    my $queue_size = scalar(@{ $heap->{queue} });
    if ( exists $heap->{cfg}{FlushSize} && $heap->{cfg}{FlushSize} > 0
            && $queue_size >= $heap->{cfg}{FlushSize}
            && !exists $heap->{force_flush}
    ) {
        DEBUG("Queue size target exceeded, flushing queue ". $heap->{cfg}{FlushSize} . " max, size is $queue_size" );
        $heap->{force_flush} = 1;
        $heap->{flush_requested} = time;
        $kernel->yield( 'flush' );
    }
}

=item B<flush>

Schedule a flush of the existing bulk updates to the cluster.  It should never
be necessary to call this event unless you'd like to shutdown the event loop
faster.

=for Pod::Coverage es_flush

=cut

sub es_flush {
    my ($kernel,$heap) = @_[KERNEL,HEAP];

    # Remove the scheduler bit for this event:
    $kernel->delay('flush');

    my $count_docs = exists $heap->{queue} && is_arrayref($heap->{queue}) ? scalar(@{ $heap->{queue} }) : 0;

    if( $count_docs > 0 ) {
        INFO(sprintf "es_flush(%0.3fs by %s) of %d documents, HTTP pool queued %d requests.",
            time - $heap->{flush_requested},
            exists $heap->{force_flush} ? 'force' : 'schedule',
            $count_docs,
            $kernel->call( http => 'pending_requests_count' ),
        );

        # Build the batch
        my $docs = delete $heap->{queue};
        my $batch = join '', @{ $docs };
        my $id    = sha1_hex($batch);
        DEBUG(sprintf "Storing to Heap Batch[%s] as %d bytes.", $id, length $batch );
        $heap->{batch}{$id} = $batch;

        # Send it along
        $kernel->yield( batch => $id );
    }
    else {
        DEBUG(sprintf "es_flush() called by %s without any items.",
            exists $heap->{force_flush} ? 'force' : 'schedule',
        );
    }

    # Reschedule
    delete $heap->{force_flush} if exists $heap->{force_flush};
    $heap->{flush_requested} = time + $heap->{cfg}{FlushInterval};
    $kernel->delay( flush => $heap->{cfg}{FlushInterval} );
}

=item B<backlog>

Request the disk-based backlog be processed.  You should never need to call
this event as the session will run it once it starts and if there's  data to
process, it will continue rescheduling as needed.  When a bulk operation fails
resulting in a batch file, this event is scheduled to run again.

=for Pod::Coverage es_backlog

=cut

sub es_backlog {
    my ($kernel,$heap) = @_[KERNEL,HEAP];

    delete $heap->{backlog_scheduled};

    my $max_batches = 25;
    my $batch_dir = path($heap->{cfg}{BatchDir});

    # randomize
    my @ids = shuffle map { $_->basename('.batch') }
                $batch_dir->children( qr/\.batch$/ );
    $kernel->yield( batch => $_ ) for @ids[0..$max_batches-1];

    if(@ids > $max_batches) {
        $kernel->delay( backlog => 15 );
        $heap->{backlog_scheduled} = 1;
    }
}

=for Pod::Coverage es_batch

=cut

sub es_batch {
    my  ($kernel,$heap,$id) = @_[KERNEL,HEAP,ARG0];

    return unless defined $id;

    # Only process if we're ready
    if( !$heap->{es_ready} ) {
        # Flush this batch to disk
        $kernel->yield( save => $id )
            if exists $heap->{batch}{$id};

        # Bail and rely on the disk backlog
        return;
    }

    # Get our content
    my $batch = '';
    if( exists $heap->{batch}{$id} ) {
        $batch = delete $heap->{batch}{$id};
    }
    else {
        # Read batch from disk
        my $batch_file = path($heap->{cfg}{BatchDir})->child($id . '.batch');
        if( $batch_file->is_file ) {
            # We need exclusive locking so we can brute force a batch
            # directory in a batch cleanup mode
            my $locked = lock_batch_file($batch_file);
            if( defined $locked && $locked == 1 ) {
                $batch = $batch_file->slurp_raw;
                my $lines = $batch =~ tr/\n//;
                if( $lines > 0 ) {
                    $kernel->yield(callback => consumed => int( $lines / 2 ));
                }
            }
        }
        else {
            WARN(sprintf "es_batch(%s) called for an unknown batch.", $id);
        }
    }
    return unless length $batch;

    # Build the URI
    my ($server,$port) = split /\:/, $heap->{cfg}{servers}[int rand scalar @{$heap->{cfg}{servers}}];
    my $uri = URI->new();
        $uri->scheme('http');
        $uri->host($server);
        $uri->port($port || 9200);
        $uri->path('/_bulk');

    # Build the request
    my $req = HTTP::Request->new(POST => $uri->as_string);
    $req->header('Content-Type', 'application/x-ndjson');
    $req->content($batch);

    DEBUG(sprintf "Bulk update of %d bytes being attempted to %s as %s.",
        length($batch),
        $uri->as_string,
        $id,
    );
    $kernel->post( http => request => http_resp => $req => $id );
    # Record the request
    $heap->{start}{$id} = time unless exists $heap->{start}{$id};
    $heap->{stats}{http_req} ||= 0;
    $heap->{stats}{http_req}++;
}

=back

=for Pod::Coverage http_resp

=cut

sub http_resp {
    my ($kernel,$heap,$params,$resp) = @_[KERNEL,HEAP,ARG0,ARG1];

    my $req  = $params->[0];  # HTTP::Request Object
    my $id   = $params->[1];  # Batch ID
    my $r    = $resp->[0];    # HTTP::Response Object
    my $duration = exists $heap->{start}{$id} ? time - $heap->{start}{$id} : undef;

    # We might need to batch things
    my $batch_file = path($heap->{cfg}{BatchDir})->child($id . '.batch');
    DEBUG(sprintf "http_resp(%s) %s", $id, $r->status_line);

    # Record the responses we receive
    my $resp_key = "http_resp_" . $r->is_success ? 'success' : 'failure';
    $heap->{stats}{$resp_key} ||= 0;
    $heap->{stats}{$resp_key}++;

    my $batch_created = 0;
    if( $r->is_success ) {
        my $details;
        eval {
            $details = decode_json($r->content);
        };
        if( defined $details && ref $details eq 'HASH' ) {
            INFO(sprintf "es_flush(%s) size was %d bytes for %d items, took %d ms (elapsed:%0.3fs)%s",
                $id,
                length($req->content),
                scalar(@{$details->{items}}),
                $details->{took},
                $duration,
                $details->{errors} ? ' with errors' : '',
            );
            $heap->{stats}{indexed} ||= 0;
            $heap->{stats}{indexed} += scalar@{ $details->{items} };
            if( exists $details->{errors} && $details->{errors} ) {
                $heap->{stats}{errors} ||= 0;
                $heap->{stats}{errors} += scalar grep { exists $_->{create} && exists $_->{create}{error} } @{ $details->{items} };
            }
        }
        else {
            WARN(sprintf "es_flush(%s) size was %d bytes, (elapsed:%0.3fs) but not valid JSON: %s",
                $id,
                length($req->content),
                $duration,
                $@,
            );
        }
        $batch_file->remove if $batch_file->is_file;
        delete $heap->{start}{$id};
    }
    else {
        # Write batch to disk, unless it exists.
        unless( $batch_file->is_file ) {
            my $lines = $req->content =~ tr/\n//;
            my $items = int( $lines / 2 );
            INFO(sprintf "[%d] Storing to File Batch[%s] as %d bytes, %d items. (elapsed:%0.3fs)",
                    $r->code, $id, length($req->content), $items, $duration
            );
            $batch_file->spew_raw($req->content);
            $batch_created = 1;
            $heap->{stats}{backlogged} ||= 0;
            $heap->{stats}{backlogged} += $items;
        }
        unless( exists $heap->{backlog_scheduled} ) {
            $kernel->delay_add( backlog => 60 );
            $heap->{backlog_scheduled} = 1;
        }
    }
    # Remove the lock
    unlock_batch_file($batch_file,$batch_created);
}

sub es_save {
    my ($kernel,$heap,$id) = @_[KERNEL,HEAP,ARG0];

    return unless exists $heap->{batch}{$id};

    my $content    = delete $heap->{batch}{$id};
    my $batch_file = path($heap->{cfg}{BatchDir})->child($id . '.batch');
    my $duration   = exists $heap->{start}{$id} ? time - $heap->{start}{$id} : 0;

    # Write batch to disk, unless it exists.
    unless( $batch_file->is_file ) {
        my $lines = $content =~ tr/\n//;
        my $items = int( $lines / 2 );
        INFO(sprintf "Storing to File Batch[%s] as %d bytes, %d items. (elapsed:%0.3fs)",
                $id, length($content), $items, $duration
        );
        $batch_file->spew_raw($req->content);
        $batch_created = 1;
        $heap->{stats}{backlogged} ||= 0;
        $heap->{stats}{backlogged} += $items;
    }
    unless( exists $heap->{backlog_scheduled} ) {
        $kernel->delay_add( backlog => 60 );
        $heap->{backlog_scheduled} = 1;
    }

}

# Closure for Locks
{
    my %_lock = ();

=for Pod::Coverage lock_batch_file

=cut

    sub lock_batch_file {
        my $batch_file = shift;
        my $lock_file = path($batch_file->absolute . '.lock');
        my $id = $lock_file->absolute;

        my $locked = 0;
        # We need to try to lock, but Path::Tiny doesn't support exclusive locks on
        # read operations, so we'll handle that with a lock file.
        if( !exists $_lock{$id} ) {
            $locked = eval {
                open $_lock{$id}, '>', $id or die "Cannot create lock file: $!\n";
                flock($_lock{$id}, LOCK_EX|LOCK_NB) or die "Unable to attain exclusive lock.";
                1;
            };
            if(!defined $locked) {
                DEBUG(sprintf "lock_batch_file(%s) failed: %s", $id, $@);
            }
        }
        return $locked;
    }

=for Pod::Coverage unlock_batch_file

=cut

    sub unlock_batch_file {
        my $batch_file = shift;
        my $batch_created = shift || 0;
        my $lock_file = path($batch_file->absolute . '.lock');
        my $id = $lock_file->absolute;

        if(exists $_lock{$id}) {
            eval {
                flock($_lock{$id}, LOCK_UN);
                1;
            } or do {
                DEBUG(sprintf "unlock_batch_file(%s) failed: %s, removing file anyways.", $id, $@);
            };
            close( delete $_lock{$id} );
            $lock_file->remove if $lock_file->is_file;
        }
        elsif( !$batch_created && $batch_file->is_file ) {
            WARN(sprintf "unlock_batch_file(%s) sent invalid unlock request.", $id);
        }
    }
}

# Return True
1;
