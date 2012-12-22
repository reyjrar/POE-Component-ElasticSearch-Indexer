# ABSTRACT: POE session to index data to ElasticSearch
package POE::Component::ElasticSearch::Indexer;

use strict;
use warnings;
use ElasticSearch;
use POE;

our $VERSION = 0.01;

=head1 SYNOPSIS

This POE Session is used to index data to an ElasticSearch cluster.

    use POE qw{ Component::ElasticSearch::Indexer };

    my $es_session = POE::Component::ElasticSearch::Indexer->spawn(
        Alias            => "es",      # Default
        TransportTimeout => 10,        # Default
        FlushInterval    => 30,        # Default
        FlushSize        => 100_000,   # Default
        Logger           => undef,     # Default
    );

    # Index the document using the queue for better performance
    $poe_kernel->post( es => queue => $index_name => $json_data );

    # Index the document directly
    $poe_kernel->post( es => save => $index_name => $json_data );


=head1 EXPORTS

POE::Component::ElasticSearch::Indexer does not export any symbols.

=cut

# Return True
1;
