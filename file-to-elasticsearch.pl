#!perl
#
use strict;
use warnings;

use Getopt::Long::Descriptive qw(describe_options);
use Hash::Merge::Simple qw(merge);
use JSON::MaybeXS qw(decode_json);
use Module::Load qw(load);
use Module::Loaded qw(is_loaded);
use Ref::Util qw(is_arrayref is_hashref);
use YAML ();

sub POE::Kernel::ASSERT_DEFAULT { 1 }
use POE qw(
    Component::ElasticSearch::Indexer
    Wheel::FollowTail
);

my %DEFAULT = (
    config => '/etc/file-to-elasticsearch.yaml',
);

my ($opt,$usage) = describe_options('%c %o',
    ['config|c:s', "Config file, default: $DEFAULT{config}",
        { default => $DEFAULT{config}, callback => { "must be a readable file" => sub { -r $_ } } }
    ],
    [],
    ['help', "Display this help.", { shortcircuit => 1 }],
);

if( $opt->help ) {
    print $usage->text;
    exit 0;
}

my $config = YAML::LoadFile( $opt->config );

my $main = POE::Session->create(
    inline_states => {
       _start => \&main_start,
       _stop  => \&main_stop,
       _child => \&main_child,
    },
    heap => {
        config => $config,
    },
);

POE::Kernel->run();
exit 0;

sub main_start {
    my ($kernel,$heap) = @_[KERNEL,HEAP];

    my $config = $heap->{config};
    my %defaults = (
        interval => 5,
        index    => 'logstash-%Y.%m.%d',
    );
    foreach my $tail ( @{ $config->{tail} } ) {
        if( -r $tail->{file} ) {
            my $wheel = POE::Wheel::FollowTail->new(
                Filename     => $tail->{file},
                InputEvent   => 'got_new_line',
                ErrorEvent   => 'got_error',
                PollInterval => $tail->{interval} || $defaults{interval},
            );
            $heap->{wheels}{$wheel->ID} = $wheel;
        }
    }

    my $es = $config->{elasticsearch} || {};
    $heap->{elasticsearch} = POE::Component::ElasticSearch::Indexer->spawn(
        Alias         => 'es',
        Servers       => $es->{servers} || [qw( localhost:9200 )],
        Timeout       => $es->{timeout} || 5,
        FlushInterval => $es->{flush_interval} || 10,
        FlushSize     => $es->{flush_size} || 100,
    );
}

sub main_stop {
    $poe_kernel->post( es => 'shutdown' );
}

sub main_child {
    my ($kernel,$heap) = @_[KERNEL,HEAP];
}

sub got_error {
    my ($kernel,$heap,$operation,$errnum,$errstr,$wheel_id) = @_[KERNEL,HEAP,ARG0..ARG3];

    # Remove the Wheel from the polling
    if( exists $heap->{wheels}{$wheel_id} ) {
        delete $heap->{wheels}{$wheel_id};
    }

    # Close the ElasticSearch session if this is the last wheel
    if( !keys %{ $heap->{wheel} } ) {
        $kernel->post( es => 'shutdown' );
    }
}

sub got_new_line {
    my ($kernel,$heap,$line,$wheel_id) = @_[KERNEL,HEAP,ARG0,ARG1];

    my $instr = $heap->{wheels}{$wheel_id};

    my $doc;
    if( $instr->{decode} ) {
        my $decoders = is_arrayref($instr->{decode}) ? $instr->{decode} : [ $instr->{decode} ];
        foreach my $decoder ( @{ $decoders } ) {
            if( $decoder eq 'json' ) {
                my $start = index('{', $line);
                my $blob  = $start > 0 ? substr($line,$start) : $line;
                my $new;
                eval {
                    $new = decode_json($blob);
                    1;
                } or do {
                    next;
                };
                $doc = merge( $doc, $new );
            }
            elsif( $decoder eq 'syslog' ) {
                unless( is_loaded('Parse::Syslog::Line') ) {
                    eval {
                        load "Parse::Syslog::Line";
                        1;
                    } or do {
                        my $err = $@;
                        die "To use the 'syslog' decoder, please install Parse::Syslog::Line: $err";
                    };
                }
                # If we make it here, we're ready to parse
                $doc = parse_syslog_line($line);
            }
        }
    }

    # Extractors
    if( my $extracters = $instr->{extract} ) {
        foreach my $extract( @{ $extracters } ) {
            # Only process items with a "by"
            if( $extract->{by} ) {
                my $from = $extract->{from} || $line;
                if( $extract->{when} ) {
                    next unless $from =~ /$extract->{when}/;
                }
                if( $extract->{by} eq 'split' ) {
                    next unless $extract->{split_on};
                    my @parts = split /$extract->{split_on}/, $from;
                    if( my $keys = $extract->{split_parts} ) {
                        # Name parts
                        for( my $i = 0; $i < @parts; $i++ ) {
                            next unless $keys->[$i] and $parts[$i];
                            if( my $into = $extract->{into} ) {
                                # Make sure we have a hash reference
                                $doc ||=  {};
                                $doc->{$into} = {} unless is_hashref($doc->{$into});
                                $doc->{$into}{$keys->[$i]} = $parts[$i];
                            }
                            else {
                                $doc ||=  {};
                                $doc->{$keys->[$i]} = $parts[$i];
                            }
                        }
                    }
                    else {
                        # This is an array, so it's simple
                        my $target = $extract->{into} ? $extract->{into} : $extract->{from};
                        $doc->{$target} = @parts > 1  ? [ grep { defined and length } @parts ] : $parts[0];
                    }
                }
                elsif( $extract->{by} eq 'regex' ) {
                    # TODO: Regex Decoder
                }
            }
        }
    }

    # Skip if the document isn't put together yet
    return unless $doc;

    # Store Line in _raw now
    $doc->{_raw} = $line;

    # Mutators
    if( my $mutate = $instr->{mutate} ) {
        # Copy
        if( my $copy = $mutate->{copy} ) {
            foreach my $k ( keys %{ $copy } ) {
                my $destinations = is_arrayref($copy->{$k}) ? $copy->{$k} : [ $copy->{$k} ];
                foreach my $dst ( @{ $destinations } ) {
                    $doc->{$dst} = $doc->{$k};
                }
            }
        }
        # Rename Keys
        if( my $rename = $mutate->{rename} ) {
            foreach my $k ( keys %{ $rename } ) {
                next unless exists $doc->{$k};
                $doc->{$rename->{$k}} = delete $doc->{$k};
            }
        }
        # Remove unwanted keys
        if( $mutate->{remove} ) {
            foreach my $k ( @{ $mutate->{remove} } ) {
                delete $doc->{$k} if exists $doc->{$k};
            }
        }
        # Append
        if( my $append = $mutate->{append} ) {
            foreach my $k ( keys %{ $append } ) {
                $doc ||=  {};
                $doc->{$k} = $append->{$k};
            }
        }
        # Prune empty or undefined keys
        if( $mutate->{prune} ) {
            foreach my $k (keys %{ $doc }) {
                delete $doc->{$k} unless defined $doc->{$k} and length $doc->{$k};
            }
        }
    }

    # Send the document to ElasticSearch
    $kernel->post( es => queue => $doc );
}
