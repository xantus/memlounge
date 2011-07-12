package Proxy::Memcached;

use bytes;
use strict;
use warnings;

sub new {
    my $class = shift;
    bless({
        connections => {},
        @_
    }, ref $class || $class );
}

sub get_connections {
    shift->{connections};
}

sub get {
    my ( $self, $con ) = @_;

    return $self->{connections}->{ "$con" };
}

sub set {
    my ( $self, $con ) = @_;

    return $self->{connections}->{ "$con" } = {
        buffer_in => '',
        buffer_out => '',
        idx_in => 0,
        idx_out => 0,
        len_in => 0,
        len_out => 0,
    };
}

sub remove {
    my ( $self, $con ) = @_;

    return delete $self->{connections}->{ "$con" };
}

sub link {
    my ( $self, $loop, $con, $link ) = @_;

    return unless my $data = $self->get( $con );

    if ( length $data->{buffer_in} ) {
        $loop->write( $link, $data->{buffer_in} );
        $data->{buffer_in} = '';
        $data->{len_in} = 0;
    }

    delete $data->{_link};

    return $data->{link} = $link;
}

sub unlink {
    my ( $self, $loop, $con ) = @_;

    return unless my $data = $self->get( $con );

    $loop->drop( $data->{link} ) if $data->{link};
    $loop->drop( $con );

    return delete $data->{link};
}

sub cleanup { 
    my ( $self, $con, $reason ) = @_;

#    return unless my $data = $self->get( $con );
}

sub on_close {
    my ( $self, $loop, $con ) = @_;

    warn "eof (eof) ".localtime()." $con - The inbound connection closed\n";

    $self->unlink( $loop, $con );
    $self->cleanup( $con );
    $self->remove( $con );

    return;
}

sub on_error {
    my ( $self, $loop, $con ) = @_;

    warn "eof (error) ".localtime()." $con - The inbound connection closed due to an error\n";

    $self->unlink( $loop, $con );
    $self->cleanup( $con );
    $self->remove( $con );

    return;
}

sub on_read {
    my ( $self, $loop, $con, $chunk ) = @_;

    my $data = $self->get( $con );

    if ( defined $chunk ) {
        $data->{buffer_in} .= $chunk;
        $data->{len_in} += length $chunk;
    }
    # TODO check buffer size

    return unless my $link = $data->{link};

    # framing
    while ( 1 ) {
        # moving window search
        my $idx = index( $data->{buffer_in}, "\x0d\x0a", $data->{idx_in} || 0 );
        if ( $idx == -1 ) {
            $data->{idx_in} = $data->{len_in};
            last;
        }

        my $frame = substr( $data->{buffer_in}, 0, $idx + 2, '' );
        $data->{idx_in} = 0;
        $data->{len_in} -= $idx + 2;

        #my $dbg = "$frame";
        #$dbg =~ s/\x0d/\\x0d/g;
        #$dbg =~ s/\x0a/\\x0a/g;
        #print STDERR "in>$dbg\n";
        #$self->log( $con, " in", substr( $frame, 0, $idx ) );

        $loop->write( $link, $frame );
    }
}

sub on_accept {
    my ( $self, $loop, $con ) = @_;

    print STDERR "connected $con\n";

    $loop->connection_timeout( $con, 100000 );

    $self->set( $con )->{_link} = $loop->connect(
        address => $self->{proxy_address},
        port => $self->{proxy_port},
        connect_timeout => 10,
        on_connect => sub { $self->on_client_connect( $con, @_ ); },
        on_read => sub { $self->on_client_read( $con, @_ ); },
        on_error => sub { $self->on_client_error( $con, @_ ); },
        on_close => sub { $self->on_client_close( $con, @_ ); }
    );
}


sub on_client_connect {
    my ( $self, $con, $loop, $link ) = @_;

    print STDERR "link connected $con -> $link\n";

    $loop->connection_timeout( $link, 100000 );

    $self->link( $loop, $con, $link );

    # fake a read, so we can flush the buffer (if any)
    $self->on_read( $loop, $con );
}

sub on_client_read {
    my ( $self, $con, $loop, $link, $chunk ) = @_;

    my $data = $self->get( $con );

    $data->{buffer_out} .= $chunk;
    $data->{len_out} += length $chunk;

#    return unless length $data->{len_out};

    # TODO check buffer size

    # framing
    while ( 1 ) {
        # moving window search
        my $idx = index( $data->{buffer_out}, "\x0d\x0a", $data->{idx_out} || 0 );
        if ( $idx == -1 ) {
            $data->{idx_out} = $data->{len_out};
            last;
        }
        my $frame = substr( $data->{buffer_out}, 0, $idx + 2, '' );
        $data->{idx_out} = 0;
        $data->{len_out} -= $idx + 2;

        #my $dbg = "$frame";
        #$dbg =~ s/\x0d/\\x0d/g;
        #$dbg =~ s/\x0a/\\x0a/g;
        #print STDERR "out>$dbg\n";
        #$self->log( $con, "out", substr( $frame, 0, $idx ) );

        $loop->write( $con, $frame );
    }

    return;
}

sub on_client_error {
    my ( $self, $con, $loop, $link ) = @_;

    warn "link eof (error) ".localtime()." $con - $link - The outbound connection closed due to an error\n";

    $self->unlink( $loop, $con );
    $self->remove( $link );
    $self->remove( $con );

    return;
}

sub on_client_close {
    my ( $self, $con, $loop, $link ) = @_;

    warn "link eof (eof) ".localtime()." $con - $link - The outbound closed the connection\n";

    $self->unlink( $loop, $con );
    $self->remove( $link );
    $self->remove( $con );

    return;
}

sub listen {
    my ( $self, $ioloop, $address, $port ) = @_;

    # The loop
    $ioloop->listen(
        address => $address,
        port    => $port,
        on_accept => sub { $self->on_accept( @_ ); },
        on_read => sub { $self->on_read( @_ ); },
        on_close => sub { $self->on_close( @_ ); },
        on_error => sub { $self->on_error( @_ ); }
    ) or die "Couldn't create listen socket!\n";
}

1;
