package Mojo::IOWatcher::EV;

use Mojo::Base 'Mojo::IOWatcher';

use EV;

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);
    #$self->{signals}->{INT} = EV::signal('QUIT', sub {
    #    warn "SIG INT\n";
    #    die;
    #});
    return $self;
}

sub add {
  my $self   = shift;
  my $handle = shift;
  my $args   = {@_, handle => $handle};

  $self->{handles}->{fileno $handle} = $args;
  $args->{on_writable}
    ? $self->writing($handle)
    : $self->not_writing($handle);

  return $self;
}

sub remove {
  my ($self, $handle) = @_;
  delete $self->{handles}->{fileno $handle};
  return $self;
}

sub one_tick {
    my ($self, $timeout) = @_;

    # TODO can this be done better?
    $self->{tick} = EV::timer($timeout, 0, \&_unloop) if $timeout;

    EV::loop;

    delete $self->{tick};

    return;
}

sub _unloop {
    EV::unloop(EV::BREAK_ONE);
}

sub recurring {
    my $self = shift;
    my $secs = shift;
    $self->_timer_event($secs => $secs => @_);
}

sub timer {
    my $self = shift;
    my $secs = shift;
    $self->_timer_event($secs => 0 => @_);
}

sub cancel {
  my ($self, $id) = @_;
  return 1 if delete $self->{timers}->{$id};
  return;
}

*watch = *one_tick;
sub _watch {
    my $self = shift;

    EV::suspend;

    $self->one_tick(@_);

    EV::resume;

    return;
}

sub writing {
    my $self = shift;

    my $fileno = fileno $_[0];

    #$self->{handles}->{$fileno}->{writing} = 1;

    my $w = $self->{handles}->{$fileno}->{watcher};
    if ($w) {
        $w->set($fileno, EV::WRITE | EV::READ);
    } else {
        $w = $self->{handles}->{$fileno}->{watcher} = EV::io(
            $fileno,
            EV::WRITE | EV::READ,
            \&_callback
        );
        $w->data( [ $self, $fileno ] );
    }

    return $self;
}

sub not_writing {
    my $self = shift;

    my $fileno = fileno $_[0];
    my $w = $self->{handles}->{$fileno}->{watcher};
    if ($w) {
        #delete $self->{handles}->{$fileno}->{writing};
        $w->set($fileno, EV::READ);
    } else {
        $w = $self->{handles}->{$fileno}->{watcher} = EV::io(
            $fileno,
            EV::READ,
            \&_callback
        );
        $w->data( [ $self, $fileno ] );
    }

    return $self;
}

sub _callback {
    my ($w, $revents) = @_;
    my ($self, $fileno) = @{ $w->data };
    my $h = $self->{handles}->{$fileno};


    $self->_sandbox('Read', $h->{on_readable}, $h->{handle})
        if EV::READ & $revents;

    $self->_sandbox('Write', $h->{on_writable}, $h->{handle})
        if EV::WRITE & $revents;

    return;
}

sub _timer_event {
    my $self   = shift;
    my $after  = shift;
    my $repeat = shift;
    my $cb     = shift;

    # Events have an id for easy removal
    my $e = {cb => $cb, @_};
    (my $id) = "$e" =~ /0x([\da-f]+)/;
    $self->{timers}->{$id} = $e;

    $e->{watcher} = EV::timer($after, $repeat, \&_timer_callback);
    $e->{watcher}->data( [ $self, $id, $repeat ? 0 : 1 ] );

    return $id;
}

sub _timer_callback {
    my $w = shift;
    my ($self, $id, $cleanup) = @{ $w->data };

    $self->_sandbox("Timer $id", $self->{timers}->{$id}->{cb}, $id);

    delete $self->{timers}->{$id} if $cleanup;

    return;
}

sub _sandbox {
    my $self = shift;
    my $desc = shift;
    return unless my $cb = shift;

    warn "$desc failed: $@" unless eval { $self->$cb(@_); 1 };
}

1;
__END__

=head1 NAME

Mojo::IOWatcher::EV - EV Async IO Watcher

=head1 SYNOPSIS

  use Mojo::IOWatcher::EV;
  use Mojo::IOLoop;

  Mojo::IOLoop->singleton->iowatcher( Mojo::IOWatcher::EV->new );

=head1 DESCRIPTION

L<Mojo::IOWatcher> is a minimalistic async io watcher with lib C<EV> support.
Note that this module is EXPERIMENTAL and might change without warning!

=head1 METHODS

L<Mojo::IOWatcher::EV> inherits all methods from L<Mojo::IOWatcher>.

=head1 SEE ALSO

L<EV>, L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
