package Test::Builder;

use 5.006;
use strict;
use warnings;

our $VERSION = '1.302012_003';
$VERSION = eval $VERSION;    ## no critic (BuiltinFunctions::ProhibitStringyEval)

BEGIN {
    if( $] < 5.008 ) {
        require Test::Builder::IO::Scalar;
    }
}

use overload();
use Data::Dumper();

use Scalar::Util qw/blessed reftype weaken/;

use Test::Stream::Sync;

use Test::Stream::Util qw/USE_THREADS try/;
# Make Test::Builder thread-safe for ithreads.
BEGIN {
    if (USE_THREADS) {
        require Test::Stream::IPC;
        require Test::Stream::IPC::Files;
        Test::Stream::IPC::Files->import;
        Test::Stream::IPC->enable_polling;
    }
}

use Test::Stream::Context qw/context release/;
use Test::Stream::Plugin::Subtest qw/subtest_streamed/;
use Test::Stream::Event::Subtest;
use Test::Stream::Formatter::TAP qw/OUT_STD OUT_ERR OUT_TODO/;
use Test::Stream::Hub::Subtest;

our $Test = Test::Builder->new;
our $Level;

Test::Stream::Sync->add_hook(sub {
    my ($ctx, $real, $new) = @_;
    $Test->_ending($ctx, $real, $new);
});

Test::Stream::Sync->ipc->set_no_fatal(1) if USE_THREADS;

sub _add_ts_hooks {
    my $self = shift;
    my $hub = $self->{Stack}->top;

    # Take a reference to the hash key, we do this to avoid closing over $self
    # which is the singleton. We use a reference because the value could change
    # in rare cases.
    my $epkgr = \$self->{Exported_To};

    $hub->add_context_init(sub {
        my $ctx = shift;
        return if defined $ctx->{debug}->{todo};

        my $epkg = $$epkgr;
        my $cpkg = $ctx->{debug}->{frame}->[0];

        no strict 'refs';
        no warnings 'once';
        my $todo;
        $todo = ${"$cpkg\::TODO"};
        $todo = ${"$epkg\::TODO"} if $epkg && !$todo;
        $ctx->{debug}->{todo} = $todo if $todo;
    });
}

sub new {
    my($class) = shift;
    unless($Test) {
        my $ctx = context();
        $Test = $class->create(singleton => 1);
        $ctx->release;
    }
    return $Test;
}

sub create {
    my $class = shift;
    my %params = @_;

    my $self = bless {}, $class;
    if ($params{singleton}) {
        $self->{Stack} = Test::Stream::Sync->stack;
    }
    else {
        $self->{Stack} = Test::Stream::Stack->new;
        $self->{Stack}->new_hub(
            formatter => Test::Stream::Formatter::TAP->new,
            ipc       => Test::Stream::Sync->ipc,
        );
    }
    $self->reset;
    $self->_add_ts_hooks;

    return $self;
}

sub ctx {
    my $self = shift;
    # 1 - call to this sub
    # Default $Level = 1 - call to $Test->...
    # $Level Additional levels to go back
    my $level = $Level + 1;

    context(
        level   => $level,
        fudge   => 1,
        stack   => $self->{Stack},
        hub     => $self->{Hub},
        wrapped => 1,
        @_
    );
}

sub parent {
    my $self = shift;
    my $ctx = $self->ctx;
    my $chub = $self->{Hub} || $ctx->hub;
    $ctx->release;

    my $parent = $chub->meta(__PACKAGE__, {})->{parent};

    return undef unless $parent;

    return bless {
        Original_Pid => $$,
        Stack => $self->{Stack},
        Hub => $parent,
    }, blessed($self);
}

sub child {
    my( $self, $name ) = @_;

    $name ||= "Child of " . $self->name;
    my $ctx = $self->ctx;

    my $parent = $ctx->hub;
    my $pmeta = $parent->meta(__PACKAGE__, {});
    $self->croak("You already have a child named ($pmeta->{child}) running")
        if $pmeta->{child};

    $pmeta->{child} = $name;

    # Clear $TODO for the child.
    my $orig_TODO = $self->find_TODO(undef, 1, undef);

    my $subevents = [];

    my $hub = $ctx->stack->new_hub(
        class => 'Test::Stream::Hub::Subtest',
    );

    $hub->listen(sub { push @$subevents => $_[1] });

    $hub->set_nested( $parent->isa('Test::Stream::Hub::Subtest') ? $parent->nested + 1 : 1 );

    $hub->set_parent_todo(1) if $ctx->debug->no_diag;

    my $meta = $hub->meta(__PACKAGE__, {});
    $meta->{Name} = $name;
    $meta->{TODO} = $orig_TODO;
    $meta->{TODO_PKG} = $ctx->debug->package;
    $meta->{parent} = $parent;
    $meta->{Test_Results} = [];
    $meta->{subevents} = $subevents;

    $self->_add_ts_hooks;

    $ctx->release;
    return bless { Original_Pid => $$, Stack => $self->{Stack}, Hub => $hub }, blessed($self);
}

sub finalize {
    my $self = shift;
    my $ok = 1;
    ($ok) = @_ if @_;

    my $st_ctx = $self->ctx;
    my $chub = $self->{Hub} || return release $st_ctx;

    my $meta = $chub->meta(__PACKAGE__, {});
    if ($meta->{child}) {
        $self->croak("Can't call finalize() with child ($meta->{child}) active");
    }

    local $? = 0;     # don't fail if $subtests happened to set $? nonzero

    $self->{Stack}->pop($chub);

    $self->find_TODO($meta->{TODO_PKG}, 1, $meta->{TODO});

    my $parent = $self->parent;
    my $ctx = $parent->ctx;
    my $dbg = $ctx->debug;
    delete $ctx->hub->meta(__PACKAGE__, {})->{child};

    my $state = $chub->state;
    $chub->finalize($dbg, 1)
        if $ok
        && $state->count
        && !$chub->no_ending
        && !$chub->state->ended;

    my $plan   = $state->plan || 0;
    my $count  = $state->count;
    my $failed = $state->failed;

    my $num_extra = $plan =~ m/\D/ ? 0 : $count - $plan;
    if ($count && $num_extra != 0) {
        my $s = $plan == 1 ? '' : 's';
        $st_ctx->diag(<<"FAIL");
Looks like you planned $plan test$s but ran $count.
FAIL
    }

    if ($failed) {
        my $s = $failed == 1 ? '' : 's';

        my $qualifier = $num_extra == 0 ? '' : ' run';

        $st_ctx->diag(<<"FAIL");
Looks like you failed $failed test$s of $count$qualifier.
FAIL
    }

    $st_ctx->release;

    unless ($state->bailed_out) {
        my $plan = $state->plan;
        if ( $plan && $plan eq 'SKIP' ) {
            $parent->skip($state->skip_reason, $meta->{Name});
        }
        elsif ( !$state->count ) {
            $parent->ok( 0, sprintf q[No tests run for subtest "%s"], $meta->{Name} );
        }
        else {
            $parent->{subevents} = $meta->{subevents};
            $parent->ok( $state->is_passing, $meta->{Name} );
        }
    }

    $ctx->release;
    return $state->is_passing;
}

sub subtest {
    my $self = shift;
    my ($name, $code, @args) = @_;
    my $ctx = $self->ctx;
    $ctx->throw("subtest()'s second argument must be a code ref")
        unless $code && reftype($code) eq 'CODE';

    $name ||= "Child of " . $self->name;

    $ctx->note("Subtest: $name");

    my $child = $self->child($name);

    my $start_pid = $$;
    my $st_ctx;
    my ($ok, $err, $finished);
    TS_SUBTEST_WRAPPER: {
        my $ctx = $self->ctx;
        $st_ctx = $ctx->snapshot;
        $ctx->release;
        ($ok, $err) = try { local $Level = 1; $code->(@args) };

        # They might have done 'BEGIN { skip_all => "whatever" }'
        if (!$ok && $err =~ m/Label not found for "last TS_SUBTEST_WRAPPER"/) {
            $ok  = undef;
            $err = undef;
        }
        else {
            $finished = 1;
        }
    }

    if ($start_pid != $$ && !$INC{'Test/Stream/IPC.pm'}) {
        warn $ok ? "Forked inside subtest, but subtest never finished!\n" : $err;
        exit 255;
    }

    my $dbg = $ctx->debug;

    if (!$finished) {
        if(my $bailed = $st_ctx->hub->bailed_out) {
            $ctx->bail($bailed->reason);
        }
        my $code = $st_ctx->hub->exit_code;
        $ok = !$code;
        $err = "Subtest ended with exit code $code" if $code;
    }

    my $state = $st_ctx->hub->state;
    my $plan  = $state->plan;
    my $count = $state->count;

    if (!$count && (!defined($plan) || "$plan" ne 'SKIP')) {
        $st_ctx->plan(0) unless defined $plan;
        $st_ctx->diag('No tests run!');
    }

    $child->finalize($ok);

    $ctx->release;

    die $err unless $ok;

    return $st_ctx->hub->state->is_passing;
}

sub name {
    my $self = shift;
    my $ctx = $self->ctx;
    release $ctx, $ctx->hub->meta(__PACKAGE__, {})->{Name};
}

sub reset {    ## no critic (Subroutines::ProhibitBuiltinHomonyms)
    my ($self) = @_;

    # We leave this a global because it has to be localized and localizing
    # hash keys is just asking for pain.  Also, it was documented.
    $Level = 1;

    $self->{Original_Pid} = $$;

    my $ctx = $self->ctx;
    $ctx->hub->set_state(Test::Stream::State->new());

    my $meta = $ctx->hub->meta(__PACKAGE__, {});
    %$meta = (
        Name         => $0,
        Ending       => 0,
        Done_Testing => undef,
        Skip_All     => 0,
        Test_Results => [],
    );

    $self->{Exported_To} = undef;

    $self->{Orig_Handles} ||= do {
        my $format = $ctx->hub->format;
        my $out;
        if ($format && $format->isa('Test::Stream::Formatter::TAP')) {
            $out = $format->handles;
        }
        $out ? [@$out] : [];
    };

    $self->use_numbers(1);
    $self->no_header(0);
    $self->no_ending(0);
    $self->reset_outputs;

    $ctx->release;

    return;
}


my %plan_cmds = (
    no_plan  => \&no_plan,
    skip_all => \&skip_all,
    tests    => \&_plan_tests,
);

sub plan {
    my( $self, $cmd, $arg ) = @_;

    return unless $cmd;

    my $ctx = $self->ctx;
    my $state = $ctx->hub->state;

    $ctx->throw("You tried to plan twice") if $state->plan;

    local $Level = $Level + 1;

    if( my $method = $plan_cmds{$cmd} ) {
        local $Level = $Level + 1;
        $self->$method($arg);
    }
    else {
        my @args = grep { defined } ( $cmd, $arg );
        $ctx->throw("plan() doesn't understand @args");
    }

    release $ctx, 1;
}


sub _plan_tests {
    my($self, $arg) = @_;

    my $ctx = $self->ctx;

    if($arg) {
        local $Level = $Level + 1;
        $self->expected_tests($arg);
    }
    elsif( !defined $arg ) {
        $ctx->throw("Got an undefined number of tests");
    }
    else {
        $ctx->throw("You said to run 0 tests");
    }

    release $ctx;
}


sub expected_tests {
    my $self = shift;
    my($max) = @_;

    my $ctx = $self->ctx;

    if(@_) {
        $self->croak("Number of tests must be a positive integer.  You gave it '$max'")
          unless $max =~ /^\+?\d+$/;

        $ctx->plan($max);
    }

    my $state = $ctx->hub->state;

    $ctx->release;

    my $plan = $state->plan;
    return 0 unless $plan;
    return 0 if $plan =~ m/\D/;
    return $plan;
}


sub no_plan {
    my($self, $arg) = @_;

    my $ctx = $self->ctx;

    $ctx->alert("no_plan takes no arguments") if $arg;

    $ctx->hub->state->plan('NO PLAN');

    release $ctx, 1;
}


sub done_testing {
    my($self, $num_tests) = @_;

    my $ctx = $self->ctx;

    my $meta = $ctx->hub->meta(__PACKAGE__, {});

    if ($meta->{Done_Testing}) {
        my ($file, $line) = @{$meta->{Done_Testing}}[1,2];
        local $ctx->hub->state->{ended}; # OMG This is awful.
        $self->ok(0, "done_testing() was already called at $file line $line");
        $ctx->release;
        return;
    }
    $meta->{Done_Testing} = [$ctx->debug->call];

    my $plan = $ctx->hub->state->plan;
    my $count = $ctx->hub->state->count;

    # If done_testing() specified the number of tests, shut off no_plan
    if( $plan && defined $num_tests ) {
        if ($plan eq 'NO PLAN') {
            $ctx->plan($num_tests);
        }
    }
    elsif ($count && defined $num_tests && $count != $num_tests) {
        $self->ok(0, "planned to run @{[ $self->expected_tests ]} but done_testing() expects $num_tests");
    }
    else {
        $num_tests = $self->current_test;
    }

    if( $self->expected_tests && $num_tests != $self->expected_tests ) {
        $self->ok(0, "planned to run @{[ $self->expected_tests ]} ".
                     "but done_testing() expects $num_tests");
    }

    $ctx->plan($num_tests) if $ctx->hub->state->plan && $ctx->hub->state->plan eq 'NO PLAN';

    $ctx->hub->finalize($ctx->debug, 1);

    release $ctx, 1;
}


sub has_plan {
    my $self = shift;

    my $ctx = $self->ctx;
    my $plan = $ctx->hub->state->plan;
    $ctx->release;

    return( $plan ) if $plan && $plan !~ m/\D/;
    return('no_plan') if $plan && $plan eq 'NO PLAN';
    return(undef);
}


sub skip_all {
    my( $self, $reason ) = @_;

    my $ctx = $self->ctx;

    $ctx->hub->meta(__PACKAGE__, {})->{Skip_All} = $reason || 1;

    # Work around old perl bug
    if ($] < 5.020000) {
        my $begin = 0;
        my $level = 0;
        while (my @call = caller($level++)) {
            last unless @call && $call[0];
            next unless $call[3] =~ m/::BEGIN$/;
            $begin++;
            last;
        }
        # HACK!
        die 'Label not found for "last TS_SUBTEST_WRAPPER"' if $begin && $ctx->hub->meta(__PACKAGE__, {})->{parent};
    }

    $ctx->plan(0, SKIP => $reason);
}


sub exported_to {
    my( $self, $pack ) = @_;

    if( defined $pack ) {
        $self->{Exported_To} = $pack;
    }
    return $self->{Exported_To};
}


sub ok {
    my( $self, $test, $name ) = @_;

    my $ctx = $self->ctx;

    # $test might contain an object which we don't want to accidentally
    # store, so we turn it into a boolean.
    $test = $test ? 1 : 0;

    # In case $name is a string overloaded object, force it to stringify.
    no  warnings qw/uninitialized numeric/;
    $name = "$name" if defined $name;

    # Profiling showed that the regex here was a huge time waster, doing the
    # numeric addition first cuts our profile time from ~300ms to ~50ms
    $self->diag(<<"    ERR") if 0 + $name && $name =~ /^[\d\s]+$/;
    You named your test '$name'.  You shouldn't use numbers for your test names.
    Very confusing.
    ERR
    use warnings qw/uninitialized numeric/;

    my $dbg = $ctx->{debug};

    my $orig_name = $name;

    # The regex form is ~250ms, the index form is ~50ms
    #$name && $name =~ m/(?:#|\n)/ && ($name =~ s|#|\\#|g, $name =~ s{\n}{\n# }sg);
    $name && (
        (index($name, "#" ) >= 0 && $name =~ s|#|\\#|g),
        (index($name, "\n") >= 0 && $name =~ s{\n}{\n# }sg)
    );

    my $result = {
        ok => 1,
        actual_ok => $test,
        (name => defined($name) ? $name : ''),
        $dbg->{todo} ? ( reason => $dbg->{todo}, type => 'todo' )
                     : ( reason => '',           type => '' ),
    };

    @$result{ 'ok', 'actual_ok' } = ( ( $dbg->no_fail ? 1 : 0 ), 0 ) unless $test;

    $ctx->{hub}->{_meta}->{+__PACKAGE__}->{Test_Results}[ $ctx->{hub}->{state}->{count} ] = $result;

    my @attrs;
    my $subevents = delete $self->{subevents};
    my $epkg = 'Test::Stream::Event::Ok';
    if ($subevents) {
        $epkg = 'Test::Stream::Event::Subtest';
        push @attrs => (subevents => $subevents);
    }

    my $e = bless {
        debug => bless( {%$dbg}, 'Test::Stream::DebugInfo'),
        pass  => $test,
        name  => $name,
        allow_bad_name => 1,
        @attrs,
    }, $epkg;
    $e->init;

    $ctx->{hub}->send($e);

    $self->_ok_debug($dbg, $orig_name) unless($test);

    $ctx->release;
    return $test;
}

sub _ok_debug {
    my $self = shift;
    my ($dbg, $orig_name) = @_;
    my $is_todo = defined $dbg->{todo};
    my $msg = $is_todo ? "Failed (TODO)" : "Failed";
    $self->diag("\n") if $ENV{HARNESS_ACTIVE};

    my (undef, $file, $line) = $dbg->call;
    if (defined $orig_name) {
        $self->diag(qq[  $msg test '$orig_name'\n]);
        $self->diag(qq[  at $file line $line.\n]);
    }
    else {
        $self->diag(qq[  $msg test at $file line $line.\n]);
    }
}

sub _unoverload {
    my ($self, $type, $thing) = @_;

    return unless ref $$thing;
    return unless blessed($$thing) || scalar $self->_try(sub{ $$thing->isa('UNIVERSAL') });
    my $string_meth = overload::Method( $$thing, $type ) || return;
    $$thing = $$thing->$string_meth();
}

sub _unoverload_str {
    my $self = shift;

    $self->_unoverload( q[""], $_ ) for @_;
}

sub _unoverload_num {
    my $self = shift;

    $self->_unoverload( '0+', $_ ) for @_;

    for my $val (@_) {
        next unless $self->_is_dualvar($$val);
        $$val = $$val + 0;
    }
}

# This is a hack to detect a dualvar such as $!
sub _is_dualvar {
    my( $self, $val ) = @_;

    # Objects are not dualvars.
    return 0 if ref $val;

    no warnings 'numeric';
    my $numval = $val + 0;
    return ($numval != 0 and $numval ne $val ? 1 : 0);
}


sub is_eq {
    my( $self, $got, $expect, $name ) = @_;

    my $ctx = $self->ctx;

    local $Level = $Level + 1;

    if( !defined $got || !defined $expect ) {
        # undef only matches undef and nothing else
        my $test = !defined $got && !defined $expect;

        $self->ok( $test, $name );
        $self->_is_diag( $got, 'eq', $expect ) unless $test;
        $ctx->release;
        return $test;
    }

    release $ctx, $self->cmp_ok( $got, 'eq', $expect, $name );
}


sub is_num {
    my( $self, $got, $expect, $name ) = @_;
    my $ctx = $self->ctx;
    local $Level = $Level + 1;

    if( !defined $got || !defined $expect ) {
        # undef only matches undef and nothing else
        my $test = !defined $got && !defined $expect;

        $self->ok( $test, $name );
        $self->_is_diag( $got, '==', $expect ) unless $test;
        $ctx->release;
        return $test;
    }

    release $ctx, $self->cmp_ok( $got, '==', $expect, $name );
}


sub _diag_fmt {
    my( $self, $type, $val ) = @_;

    if( defined $$val ) {
        if( $type eq 'eq' or $type eq 'ne' ) {
            # quote and force string context
            $$val = "'$$val'";
        }
        else {
            # force numeric context
            $self->_unoverload_num($val);
        }
    }
    else {
        $$val = 'undef';
    }

    return;
}


sub _is_diag {
    my( $self, $got, $type, $expect ) = @_;

    $self->_diag_fmt( $type, $_ ) for \$got, \$expect;

    local $Level = $Level + 1;
    return $self->diag(<<"DIAGNOSTIC");
         got: $got
    expected: $expect
DIAGNOSTIC

}

sub _isnt_diag {
    my( $self, $got, $type ) = @_;

    $self->_diag_fmt( $type, \$got );

    local $Level = $Level + 1;
    return $self->diag(<<"DIAGNOSTIC");
         got: $got
    expected: anything else
DIAGNOSTIC
}


sub isnt_eq {
    my( $self, $got, $dont_expect, $name ) = @_;
    my $ctx = $self->ctx;
    local $Level = $Level + 1;

    if( !defined $got || !defined $dont_expect ) {
        # undef only matches undef and nothing else
        my $test = defined $got || defined $dont_expect;

        $self->ok( $test, $name );
        $self->_isnt_diag( $got, 'ne' ) unless $test;
        $ctx->release;
        return $test;
    }

    release $ctx, $self->cmp_ok( $got, 'ne', $dont_expect, $name );
}

sub isnt_num {
    my( $self, $got, $dont_expect, $name ) = @_;
    my $ctx = $self->ctx;
    local $Level = $Level + 1;

    if( !defined $got || !defined $dont_expect ) {
        # undef only matches undef and nothing else
        my $test = defined $got || defined $dont_expect;

        $self->ok( $test, $name );
        $self->_isnt_diag( $got, '!=' ) unless $test;
        $ctx->release;
        return $test;
    }

    release $ctx, $self->cmp_ok( $got, '!=', $dont_expect, $name );
}


sub like {
    my( $self, $thing, $regex, $name ) = @_;
    my $ctx = $self->ctx;

    local $Level = $Level + 1;

    release $ctx, $self->_regex_ok( $thing, $regex, '=~', $name );
}

sub unlike {
    my( $self, $thing, $regex, $name ) = @_;
    my $ctx = $self->ctx;

    local $Level = $Level + 1;

    release $ctx, $self->_regex_ok( $thing, $regex, '!~', $name );
}


my %numeric_cmps = map { ( $_, 1 ) } ( "<", "<=", ">", ">=", "==", "!=", "<=>" );

# Bad, these are not comparison operators. Should we include more?
my %cmp_ok_bl = map { ( $_, 1 ) } ( "=", "+=", ".=", "x=", "^=", "|=", "||=", "&&=", "...");

sub cmp_ok {
    my( $self, $got, $type, $expect, $name ) = @_;
    my $ctx = $self->ctx;

    if ($cmp_ok_bl{$type}) {
        $ctx->throw("$type is not a valid comparison operator in cmp_ok()");
    }

    my ($test, $succ);
    my $error;
    {
        ## no critic (BuiltinFunctions::ProhibitStringyEval)

        local( $@, $!, $SIG{__DIE__} );    # isolate eval

        my($pack, $file, $line) = $ctx->debug->call();

        # This is so that warnings come out at the caller's level
        $succ = eval qq[
#line $line "(eval in cmp_ok) $file"
\$test = (\$got $type \$expect);
1;
];
        $error = $@;
    }
    local $Level = $Level + 1;
    my $ok = $self->ok( $test, $name );

    # Treat overloaded objects as numbers if we're asked to do a
    # numeric comparison.
    my $unoverload
      = $numeric_cmps{$type}
      ? '_unoverload_num'
      : '_unoverload_str';

    $self->diag(<<"END") unless $succ;
An error occurred while using $type:
------------------------------------
$error
------------------------------------
END

    unless($ok) {
        $self->$unoverload( \$got, \$expect );

        if( $type =~ /^(eq|==)$/ ) {
            $self->_is_diag( $got, $type, $expect );
        }
        elsif( $type =~ /^(ne|!=)$/ ) {
            $self->_isnt_diag( $got, $type );
        }
        else {
            $self->_cmp_diag( $got, $type, $expect );
        }
    }
    return release $ctx, $ok;
}

sub _cmp_diag {
    my( $self, $got, $type, $expect ) = @_;

    $got    = defined $got    ? "'$got'"    : 'undef';
    $expect = defined $expect ? "'$expect'" : 'undef';

    local $Level = $Level + 1;
    return $self->diag(<<"DIAGNOSTIC");
    $got
        $type
    $expect
DIAGNOSTIC
}

sub _caller_context {
    my $self = shift;

    my( $pack, $file, $line ) = $self->caller(1);

    my $code = '';
    $code .= "#line $line $file\n" if defined $file and defined $line;

    return $code;
}


sub BAIL_OUT {
    my( $self, $reason ) = @_;

    my $ctx = $self->ctx;

    $self->{Bailed_Out} = 1;

    $ctx->bail($reason);
}


{
    no warnings 'once';
    *BAILOUT = \&BAIL_OUT;
}

sub skip {
    my( $self, $why, $name ) = @_;
    $why ||= '';
    $name = '' unless defined $name;
    $self->_unoverload_str( \$why );

    my $ctx = $self->ctx;

    $ctx->hub->meta(__PACKAGE__, {})->{Test_Results}[ $ctx->hub->state->count ] = {
        'ok'      => 1,
        actual_ok => 1,
        name      => $name,
        type      => 'skip',
        reason    => $why,
    };

    $name =~ s|#|\\#|g;    # # in a name can confuse Test::Harness.
    $name =~ s{\n}{\n# }sg;
    $why =~ s{\n}{\n# }sg;

    my $tctx = $ctx->snapshot;
    $tctx->debug->set_skip($why);
    $tctx->ok(1, '');

    return release $ctx, 1;
}


sub todo_skip {
    my( $self, $why ) = @_;
    $why ||= '';

    my $ctx = $self->ctx;

    $ctx->hub->meta(__PACKAGE__, {})->{Test_Results}[ $ctx->hub->state->count ] = {
        'ok'      => 1,
        actual_ok => 0,
        name      => '',
        type      => 'todo_skip',
        reason    => $why,
    };

    $why =~ s{\n}{\n# }sg;
    my $tctx = $ctx->snapshot;
    $tctx->debug->set_skip($why);
    $tctx->debug->set_todo($why);
    $tctx->send_event( 'Ok', pass => 0, name => '');

    return release $ctx, 1;
}


sub maybe_regex {
    my( $self, $regex ) = @_;
    my $usable_regex = undef;

    return $usable_regex unless defined $regex;

    my( $re, $opts );

    # Check for qr/foo/
    if( _is_qr($regex) ) {
        $usable_regex = $regex;
    }
    # Check for '/foo/' or 'm,foo,'
    elsif(( $re, $opts )        = $regex =~ m{^ /(.*)/ (\w*) $ }sx              or
          ( undef, $re, $opts ) = $regex =~ m,^ m([^\w\s]) (.+) \1 (\w*) $,sx
    )
    {
        $usable_regex = length $opts ? "(?$opts)$re" : $re;
    }

    return $usable_regex;
}

sub _is_qr {
    my $regex = shift;

    # is_regexp() checks for regexes in a robust manner, say if they're
    # blessed.
    return re::is_regexp($regex) if defined &re::is_regexp;
    return ref $regex eq 'Regexp';
}

sub _regex_ok {
    my( $self, $thing, $regex, $cmp, $name ) = @_;

    my $ok           = 0;
    my $usable_regex = $self->maybe_regex($regex);
    unless( defined $usable_regex ) {
        local $Level = $Level + 1;
        $ok = $self->ok( 0, $name );
        $self->diag("    '$regex' doesn't look much like a regex to me.");
        return $ok;
    }

    {
        my $test;
        my $context = $self->_caller_context;

        {
            ## no critic (BuiltinFunctions::ProhibitStringyEval)

            local( $@, $!, $SIG{__DIE__} );    # isolate eval

            # No point in issuing an uninit warning, they'll see it in the diagnostics
            no warnings 'uninitialized';

            $test = eval $context . q{$test = $thing =~ /$usable_regex/ ? 1 : 0};
        }

        $test = !$test if $cmp eq '!~';

        local $Level = $Level + 1;
        $ok = $self->ok( $test, $name );
    }

    unless($ok) {
        $thing = defined $thing ? "'$thing'" : 'undef';
        my $match = $cmp eq '=~' ? "doesn't match" : "matches";

        local $Level = $Level + 1;
        $self->diag( sprintf <<'DIAGNOSTIC', $thing, $match, $regex );
                  %s
    %13s '%s'
DIAGNOSTIC

    }

    return $ok;
}


sub is_fh {
    my $self     = shift;
    my $maybe_fh = shift;
    return 0 unless defined $maybe_fh;

    return 1 if ref $maybe_fh  eq 'GLOB';    # its a glob ref
    return 1 if ref \$maybe_fh eq 'GLOB';    # its a glob

    return eval { $maybe_fh->isa("IO::Handle") } ||
           eval { tied($maybe_fh)->can('TIEHANDLE') };
}


sub level {
    my( $self, $level ) = @_;

    if( defined $level ) {
        $Level = $level;
    }
    return $Level;
}


sub use_numbers {
    my( $self, $use_nums ) = @_;

    my $ctx = $self->ctx;
    my $format = $ctx->hub->format;
    return unless $format && $format->isa('Test::Stream::Formatter::TAP');

    $format->set_no_numbers(!$use_nums) if defined $use_nums;

    return release $ctx, $format->no_numbers ? 0 : 1;
}

BEGIN {
    for my $method (qw(no_header no_diag)) {
        my $set = "set_$method";
        my $code = sub {
            my( $self, $no ) = @_;

            my $ctx = $self->ctx;
            my $format = $ctx->hub->format;
            return unless $format && $format->isa('Test::Stream::Formatter::TAP');

            $format->$set($no) if defined $no;

            return release $ctx, $format->$method ? 1 : 0;
        };

        no strict 'refs';    ## no critic
        *$method = $code;
    }
}

sub no_ending {
    my( $self, $no ) = @_;

    my $ctx = $self->ctx;

    $ctx->hub->set_no_ending($no) if defined $no;

    return release $ctx, $ctx->hub->no_ending;
}

sub diag {
    my $self = shift;

    my $ctx = $self->ctx;
    $ctx->diag(join '' => map {defined($_) ? $_ : 'undef'} @_);
    release $ctx;
}


sub note {
    my $self = shift;

    my $ctx = $self->ctx;
    $ctx->note(join '' => map {defined($_) ? $_ : 'undef'} @_);
    release $ctx;
}


sub explain {
    my $self = shift;

    return map {
        ref $_
          ? do {
            my $dumper = Data::Dumper->new( [$_] );
            $dumper->Indent(1)->Terse(1);
            $dumper->Sortkeys(1) if $dumper->can("Sortkeys");
            $dumper->Dump;
          }
          : $_
    } @_;
}


sub output {
    my( $self, $fh ) = @_;

    my $ctx = $self->ctx;
    my $format = $ctx->hub->format;
    $ctx->release;
    return unless $format && $format->isa('Test::Stream::Formatter::TAP');

    $format->handles->[OUT_STD()] = $self->_new_fh($fh)
        if defined $fh;

    return $format->handles->[OUT_STD()];
}

sub failure_output {
    my( $self, $fh ) = @_;

    my $ctx = $self->ctx;
    my $format = $ctx->hub->format;
    $ctx->release;
    return unless $format && $format->isa('Test::Stream::Formatter::TAP');

    $format->handles->[OUT_ERR()] = $self->_new_fh($fh)
        if defined $fh;

    return $format->handles->[OUT_ERR()];
}

sub todo_output {
    my( $self, $fh ) = @_;

    my $ctx = $self->ctx;
    my $format = $ctx->hub->format;
    $ctx->release;
    return unless $format && $format->isa('Test::Stream::Formatter::TAP');

    $format->handles->[OUT_TODO()] = $self->_new_fh($fh)
        if defined $fh;

    return $format->handles->[OUT_TODO()];
}

sub _new_fh {
    my $self = shift;
    my($file_or_fh) = shift;

    my $fh;
    if( $self->is_fh($file_or_fh) ) {
        $fh = $file_or_fh;
    }
    elsif( ref $file_or_fh eq 'SCALAR' ) {
        # Scalar refs as filehandles was added in 5.8.
        if( $] >= 5.008 ) {
            open $fh, ">>", $file_or_fh
              or $self->croak("Can't open scalar ref $file_or_fh: $!");
        }
        # Emulate scalar ref filehandles with a tie.
        else {
            $fh = Test::Builder::IO::Scalar->new($file_or_fh)
              or $self->croak("Can't tie scalar ref $file_or_fh");
        }
    }
    else {
        open $fh, ">", $file_or_fh
          or $self->croak("Can't open test output log $file_or_fh: $!");
        _autoflush($fh);
    }

    return $fh;
}

sub _autoflush {
    my($fh) = shift;
    my $old_fh = select $fh;
    $| = 1;
    select $old_fh;

    return;
}


sub reset_outputs {
    my $self = shift;

    my $ctx = $self->ctx;
    my $format = $ctx->hub->format;
    $ctx->release;
    return unless $format && $format->isa('Test::Stream::Formatter::TAP');
    $format->set_handles([@{$self->{Orig_Handles}}]) if $self->{Orig_Handles};

    return;
}


sub carp {
    my $self = shift;
    my $ctx = $self->ctx;
    $ctx->alert(join "", @_);
    $ctx->release;
}

sub croak {
    my $self = shift;
    my $ctx = $self->ctx;
    $ctx->throw(join "", @_);
    $ctx->release;
}


sub current_test {
    my( $self, $num ) = @_;

    my $ctx = $self->ctx;
    my $state = $ctx->hub->state;

    if( defined $num ) {
        $state->set_count($num);

        # If the test counter is being pushed forward fill in the details.
        my $test_results = $ctx->hub->meta(__PACKAGE__, {})->{Test_Results};
        if( $num > @$test_results ) {
            my $start = @$test_results ? @$test_results : 0;
            for( $start .. $num - 1 ) {
                $test_results->[$_] = {
                    'ok'      => 1,
                    actual_ok => undef,
                    reason    => 'incrementing test number',
                    type      => 'unknown',
                    name      => undef
                };
            }
        }
        # If backward, wipe history.  Its their funeral.
        elsif( $num < @$test_results ) {
            $#{$test_results} = $num - 1;
        }
    }
    return release $ctx, $state->count;
}


sub is_passing {
    my $self = shift;

    my $ctx = $self->ctx;
    my $state = $ctx->hub->state;

    if( @_ ) {
        my ($bool) = @_;
        $state->set_failed(0) if $bool;
        $state->is_passing($bool);
    }

    return release $ctx, $state->is_passing;
}


sub summary {
    my($self) = shift;

    my $ctx = $self->ctx;
    my $data = $ctx->hub->meta(__PACKAGE__, {})->{Test_Results};
    $ctx->release;
    return map { $_->{'ok'} } @$data;
}


sub details {
    my $self = shift;
    my $ctx = $self->ctx;
    my $data = $ctx->hub->meta(__PACKAGE__, {})->{Test_Results};
    $ctx->release;
    return @$data;
}


sub find_TODO {
    my( $self, $pack, $set, $new_value ) = @_;

    my $ctx = $self->ctx;

    $pack = $pack || $self->caller || $self->exported_to;
    $ctx->release;

    return unless $pack;

    no strict 'refs';    ## no critic
    no warnings 'once';
    my $old_value = ${ $pack . '::TODO' };
    $set and ${ $pack . '::TODO' } = $new_value;
    return $old_value;
}

sub todo {
    my( $self, $pack ) = @_;

    my $ctx = $self->ctx;

    my $todo = $ctx->debug->todo;
    return release($ctx, $todo) if defined $todo;

    local $Level = $Level + 1;
    $todo = $self->find_TODO($pack);
    $ctx->release;

    return $todo;
}

sub in_todo {
    my $self = shift;

    my $ctx = $self->ctx;

    my $todo = $ctx->debug->todo;
    return release($ctx, 1) if defined $todo;

    local $Level = $Level + 1;
    $todo = $self->find_TODO();
    $ctx->release;

    return 0 unless defined $todo;
    return 0 if "$todo" eq '';
    return 1;
}


sub todo_start {
    my $self = shift;
    my $message = @_ ? shift : '';

    my $ctx = $self->ctx;
    my $todo = $ctx->hub->set_todo($message);
    push @{$ctx->hub->meta(__PACKAGE__, {todo => []})->{todo}} => $todo;

    $ctx->release;

    return;
}


sub todo_end {
    my $self = shift;

    my $ctx = $self->ctx;
    my $ref = pop @{$ctx->hub->meta(__PACKAGE__, {todo => []})->{todo}};

    if( !$ref ) {
        $ctx->throw('todo_end() called without todo_start()');
    }

    $ref = undef;

    $ctx->release;

    return;
}


sub caller {    ## no critic (Subroutines::ProhibitBuiltinHomonyms)
    my( $self ) = @_;

    my $ctx = $self->ctx;

    return release $ctx, wantarray ? $ctx->debug->call : $ctx->debug->package;
}


sub _try {
    my( $self, $code, %opts ) = @_;

    my $error;
    my $return;
    {
        local $!;               # eval can mess up $!
        local $@;               # don't set $@ in the test
        local $SIG{__DIE__};    # don't trip an outside DIE handler.
        $return = eval { $code->() };
        $error = $@;
    }

    die $error if $error and $opts{die_on_fail};

    return wantarray ? ( $return, $error ) : $return;
}

sub _ending {
    my $self = shift;
    my ($ctx, $real_exit_code, $new) = @_;

    unless ($ctx) {
        my $octx = $self->ctx;
        $ctx = $octx->snapshot;
        $octx->release;
    }

    return if $ctx->hub->no_ending;
    return if $ctx->hub->meta(__PACKAGE__, {})->{Ending}++;

    # Don't bother with an ending if this is a forked copy.  Only the parent
    # should do the ending.
    return unless $self->{Original_Pid} == $$;

    my $state = $ctx->hub->state;
    return if $state->bailed_out;

    my $plan  = $state->plan;
    my $count = $state->count;
    my $failed = $state->failed;
    return unless $plan || $count || $failed;

    # Ran tests but never declared a plan or hit done_testing
    if( !$state->plan and $state->count ) {
        $self->diag("Tests were run but no plan was declared and done_testing() was not seen.");

        if($real_exit_code) {
            $self->diag(<<"FAIL");
Looks like your test exited with $real_exit_code just after $count.
FAIL
            $$new ||= $real_exit_code;
            return;
        }

        # But if the tests ran, handle exit code.
        if($failed > 0) {
            my $exit_code = $failed <= 254 ? $failed : 254;
            $$new ||= $exit_code;
            return;
        }

        $$new ||= 254;
        return;
    }

    if ($real_exit_code && !$count) {
        $self->diag("Looks like your test exited with $real_exit_code before it could output anything.");
        $$new ||= $real_exit_code;
        return;
    }

    return if $plan && "$plan" eq 'SKIP';

    if (!$count) {
        $self->diag('No tests run!');
        $$new ||= 255;
        return;
    }

    if ($real_exit_code) {
        $self->diag(<<"FAIL");
Looks like your test exited with $real_exit_code just after $count.
FAIL
        $$new ||= $real_exit_code;
        return;
    }

    if ($plan eq 'NO PLAN') {
        $ctx->plan( $count );
        $plan = $state->plan;
    }

    # Figure out if we passed or failed and print helpful messages.
    my $num_extra = $count - $plan;

    if ($num_extra != 0) {
        my $s = $plan == 1 ? '' : 's';
        $self->diag(<<"FAIL");
Looks like you planned $plan test$s but ran $count.
FAIL
    }

    if ($failed) {
        my $s = $failed == 1 ? '' : 's';

        my $qualifier = $num_extra == 0 ? '' : ' run';

        $self->diag(<<"FAIL");
Looks like you failed $failed test$s of $count$qualifier.
FAIL
    }

    my $exit_code = 0;
    if ($failed) {
        $exit_code = $failed <= 254 ? $failed : 254;
    }
    elsif ($num_extra != 0) {
        $exit_code = 255;
    }

    $$new ||= $exit_code;
    return;
}

# Some things used this even though it was private... I am looking at you
# Test::Builder::Prefix...
sub _print_comment {
    my( $self, $fh, @msgs ) = @_;

    return if $self->no_diag;
    return unless @msgs;

    # Prevent printing headers when compiling (i.e. -c)
    return if $^C;

    # Smash args together like print does.
    # Convert undef to 'undef' so its readable.
    my $msg = join '', map { defined($_) ? $_ : 'undef' } @msgs;

    # Escape the beginning, _print will take care of the rest.
    $msg =~ s/^/# /;

    local( $\, $", $, ) = ( undef, ' ', '' );
    print $fh $msg;

    return 0;
}

1;

__END__

=head1 NAME

Test::Builder - Backend for building test libraries

=head1 SYNOPSIS

  package My::Test::Module;
  use base 'Test::Builder::Module';

  my $CLASS = __PACKAGE__;

  sub ok {
      my($test, $name) = @_;
      my $tb = $CLASS->builder;

      $tb->ok($test, $name);
  }


=head1 DESCRIPTION

L<Test::Simple> and L<Test::More> have proven to be popular testing modules,
but they're not always flexible enough.  Test::Builder provides a
building block upon which to write your own test libraries I<which can
work together>.

=head2 Construction

=over 4

=item B<new>

  my $Test = Test::Builder->new;

Returns a Test::Builder object representing the current state of the
test.

Since you only run one test per program C<new> always returns the same
Test::Builder object.  No matter how many times you call C<new()>, you're
getting the same object.  This is called a singleton.  This is done so that
multiple modules share such global information as the test counter and
where test output is going.

If you want a completely new Test::Builder object different from the
singleton, use C<create>.

=item B<create>

  my $Test = Test::Builder->create;

Ok, so there can be more than one Test::Builder object and this is how
you get it.  You might use this instead of C<new()> if you're testing
a Test::Builder based module, but otherwise you probably want C<new>.

B<NOTE>: the implementation is not complete.  C<level>, for example, is
still shared amongst B<all> Test::Builder objects, even ones created using
this method.  Also, the method name may change in the future.

=item B<subtest>

    $builder->subtest($name, \&subtests, @args);

See documentation of C<subtest> in Test::More.

C<subtest> also, and optionally, accepts arguments which will be passed to the
subtests reference.

=item B<name>

 diag $builder->name;

Returns the name of the current builder.  Top level builders default to C<$0>
(the name of the executable).  Child builders are named via the C<child>
method.  If no name is supplied, will be named "Child of $parent->name".

=item B<reset>

  $Test->reset;

Reinitializes the Test::Builder singleton to its original state.
Mostly useful for tests run in persistent environments where the same
test might be run multiple times in the same process.

=back

=head2 Setting up tests

These methods are for setting up tests and declaring how many there
are.  You usually only want to call one of these methods.

=over 4

=item B<plan>

  $Test->plan('no_plan');
  $Test->plan( skip_all => $reason );
  $Test->plan( tests => $num_tests );

A convenient way to set up your tests.  Call this and Test::Builder
will print the appropriate headers and take the appropriate actions.

If you call C<plan()>, don't call any of the other methods below.

If a child calls "skip_all" in the plan, a C<Test::Builder::Exception> is
thrown.  Trap this error, call C<finalize()> and don't run any more tests on
the child.

 my $child = $Test->child('some child');
 eval { $child->plan( $condition ? ( skip_all => $reason ) : ( tests => 3 )  ) };
 if ( eval { $@->isa('Test::Builder::Exception') } ) {
    $child->finalize;
    return;
 }
 # run your tests


=item B<expected_tests>

    my $max = $Test->expected_tests;
    $Test->expected_tests($max);

Gets/sets the number of tests we expect this test to run and prints out
the appropriate headers.


=item B<no_plan>

  $Test->no_plan;

Declares that this test will run an indeterminate number of tests.


=item B<done_testing>

  $Test->done_testing();
  $Test->done_testing($num_tests);

Declares that you are done testing, no more tests will be run after this point.

If a plan has not yet been output, it will do so.

$num_tests is the number of tests you planned to run.  If a numbered
plan was already declared, and if this contradicts, a failing test
will be run to reflect the planning mistake.  If C<no_plan> was declared,
this will override.

If C<done_testing()> is called twice, the second call will issue a
failing test.

If C<$num_tests> is omitted, the number of tests run will be used, like
no_plan.

C<done_testing()> is, in effect, used when you'd want to use C<no_plan>, but
safer. You'd use it like so:

    $Test->ok($a == $b);
    $Test->done_testing();

Or to plan a variable number of tests:

    for my $test (@tests) {
        $Test->ok($test);
    }
    $Test->done_testing(scalar @tests);


=item B<has_plan>

  $plan = $Test->has_plan

Find out whether a plan has been defined. C<$plan> is either C<undef> (no plan
has been set), C<no_plan> (indeterminate # of tests) or an integer (the number
of expected tests).

=item B<skip_all>

  $Test->skip_all;
  $Test->skip_all($reason);

Skips all the tests, using the given C<$reason>.  Exits immediately with 0.

=item B<exported_to>

  my $pack = $Test->exported_to;
  $Test->exported_to($pack);

Tells Test::Builder what package you exported your functions to.

This method isn't terribly useful since modules which share the same
Test::Builder object might get exported to different packages and only
the last one will be honored.

=back

=head2 Running tests

These actually run the tests, analogous to the functions in Test::More.

They all return true if the test passed, false if the test failed.

C<$name> is always optional.

=over 4

=item B<ok>

  $Test->ok($test, $name);

Your basic test.  Pass if C<$test> is true, fail if $test is false.  Just
like Test::Simple's C<ok()>.

=item B<is_eq>

  $Test->is_eq($got, $expected, $name);

Like Test::More's C<is()>.  Checks if C<$got eq $expected>.  This is the
string version.

C<undef> only ever matches another C<undef>.

=item B<is_num>

  $Test->is_num($got, $expected, $name);

Like Test::More's C<is()>.  Checks if C<$got == $expected>.  This is the
numeric version.

C<undef> only ever matches another C<undef>.

=item B<isnt_eq>

  $Test->isnt_eq($got, $dont_expect, $name);

Like L<Test::More>'s C<isnt()>.  Checks if C<$got ne $dont_expect>.  This is
the string version.

=item B<isnt_num>

  $Test->isnt_num($got, $dont_expect, $name);

Like L<Test::More>'s C<isnt()>.  Checks if C<$got ne $dont_expect>.  This is
the numeric version.

=item B<like>

  $Test->like($thing, qr/$regex/, $name);
  $Test->like($thing, '/$regex/', $name);

Like L<Test::More>'s C<like()>.  Checks if $thing matches the given C<$regex>.

=item B<unlike>

  $Test->unlike($thing, qr/$regex/, $name);
  $Test->unlike($thing, '/$regex/', $name);

Like L<Test::More>'s C<unlike()>.  Checks if $thing B<does not match> the
given C<$regex>.

=item B<cmp_ok>

  $Test->cmp_ok($thing, $type, $that, $name);

Works just like L<Test::More>'s C<cmp_ok()>.

    $Test->cmp_ok($big_num, '!=', $other_big_num);

=back

=head2 Other Testing Methods

These are methods which are used in the course of writing a test but are not themselves tests.

=over 4

=item B<BAIL_OUT>

    $Test->BAIL_OUT($reason);

Indicates to the L<Test::Harness> that things are going so badly all
testing should terminate.  This includes running any additional test
scripts.

It will exit with 255.

=for deprecated
BAIL_OUT() used to be BAILOUT()

=item B<skip>

    $Test->skip;
    $Test->skip($why);

Skips the current test, reporting C<$why>.

=item B<todo_skip>

  $Test->todo_skip;
  $Test->todo_skip($why);

Like C<skip()>, only it will declare the test as failing and TODO.  Similar
to

    print "not ok $tnum # TODO $why\n";

=begin _unimplemented

=item B<skip_rest>

  $Test->skip_rest;
  $Test->skip_rest($reason);

Like C<skip()>, only it skips all the rest of the tests you plan to run
and terminates the test.

If you're running under C<no_plan>, it skips once and terminates the
test.

=end _unimplemented

=back


=head2 Test building utility methods

These methods are useful when writing your own test methods.

=over 4

=item B<maybe_regex>

  $Test->maybe_regex(qr/$regex/);
  $Test->maybe_regex('/$regex/');

This method used to be useful back when Test::Builder worked on Perls
before 5.6 which didn't have qr//.  Now its pretty useless.

Convenience method for building testing functions that take regular
expressions as arguments.

Takes a quoted regular expression produced by C<qr//>, or a string
representing a regular expression.

Returns a Perl value which may be used instead of the corresponding
regular expression, or C<undef> if its argument is not recognised.

For example, a version of C<like()>, sans the useful diagnostic messages,
could be written as:

  sub laconic_like {
      my ($self, $thing, $regex, $name) = @_;
      my $usable_regex = $self->maybe_regex($regex);
      die "expecting regex, found '$regex'\n"
          unless $usable_regex;
      $self->ok($thing =~ m/$usable_regex/, $name);
  }


=item B<is_fh>

    my $is_fh = $Test->is_fh($thing);

Determines if the given C<$thing> can be used as a filehandle.

=cut


=back


=head2 Test style


=over 4

=item B<level>

    $Test->level($how_high);

How far up the call stack should C<$Test> look when reporting where the
test failed.

Defaults to 1.

Setting L<$Test::Builder::Level> overrides.  This is typically useful
localized:

    sub my_ok {
        my $test = shift;

        local $Test::Builder::Level = $Test::Builder::Level + 1;
        $TB->ok($test);
    }

To be polite to other functions wrapping your own you usually want to increment C<$Level> rather than set it to a constant.

=item B<use_numbers>

    $Test->use_numbers($on_or_off);

Whether or not the test should output numbers.  That is, this if true:

  ok 1
  ok 2
  ok 3

or this if false

  ok
  ok
  ok

Most useful when you can't depend on the test output order, such as
when threads or forking is involved.

Defaults to on.

=item B<no_diag>

    $Test->no_diag($no_diag);

If set true no diagnostics will be printed.  This includes calls to
C<diag()>.

=item B<no_ending>

    $Test->no_ending($no_ending);

Normally, Test::Builder does some extra diagnostics when the test
ends.  It also changes the exit code as described below.

If this is true, none of that will be done.

=item B<no_header>

    $Test->no_header($no_header);

If set to true, no "1..N" header will be printed.

=back

=head2 Output

Controlling where the test output goes.

It's ok for your test to change where STDOUT and STDERR point to,
Test::Builder's default output settings will not be affected.

=over 4

=item B<diag>

    $Test->diag(@msgs);

Prints out the given C<@msgs>.  Like C<print>, arguments are simply
appended together.

Normally, it uses the C<failure_output()> handle, but if this is for a
TODO test, the C<todo_output()> handle is used.

Output will be indented and marked with a # so as not to interfere
with test output.  A newline will be put on the end if there isn't one
already.

We encourage using this rather than calling print directly.

Returns false.  Why?  Because C<diag()> is often used in conjunction with
a failing test (C<ok() || diag()>) it "passes through" the failure.

    return ok(...) || diag(...);

=for blame transfer
Mark Fowler <mark@twoshortplanks.com>

=item B<note>

    $Test->note(@msgs);

Like C<diag()>, but it prints to the C<output()> handle so it will not
normally be seen by the user except in verbose mode.

=item B<explain>

    my @dump = $Test->explain(@msgs);

Will dump the contents of any references in a human readable format.
Handy for things like...

    is_deeply($have, $want) || diag explain $have;

or

    is_deeply($have, $want) || note explain $have;

=item B<output>

=item B<failure_output>

=item B<todo_output>

    my $filehandle = $Test->output;
    $Test->output($filehandle);
    $Test->output($filename);
    $Test->output(\$scalar);

These methods control where Test::Builder will print its output.
They take either an open C<$filehandle>, a C<$filename> to open and write to
or a C<$scalar> reference to append to.  It will always return a C<$filehandle>.

B<output> is where normal "ok/not ok" test output goes.

Defaults to STDOUT.

B<failure_output> is where diagnostic output on test failures and
C<diag()> goes.  It is normally not read by Test::Harness and instead is
displayed to the user.

Defaults to STDERR.

C<todo_output> is used instead of C<failure_output()> for the
diagnostics of a failing TODO test.  These will not be seen by the
user.

Defaults to STDOUT.

=item reset_outputs

  $tb->reset_outputs;

Resets all the output filehandles back to their defaults.

=item carp

  $tb->carp(@message);

Warns with C<@message> but the message will appear to come from the
point where the original test function was called (C<< $tb->caller >>).

=item croak

  $tb->croak(@message);

Dies with C<@message> but the message will appear to come from the
point where the original test function was called (C<< $tb->caller >>).


=back


=head2 Test Status and Info

=over 4

=item B<current_test>

    my $curr_test = $Test->current_test;
    $Test->current_test($num);

Gets/sets the current test number we're on.  You usually shouldn't
have to set this.

If set forward, the details of the missing tests are filled in as 'unknown'.
if set backward, the details of the intervening tests are deleted.  You
can erase history if you really want to.


=item B<is_passing>

   my $ok = $builder->is_passing;

Indicates if the test suite is currently passing.

More formally, it will be false if anything has happened which makes
it impossible for the test suite to pass.  True otherwise.

For example, if no tests have run C<is_passing()> will be true because
even though a suite with no tests is a failure you can add a passing
test to it and start passing.

Don't think about it too much.


=item B<summary>

    my @tests = $Test->summary;

A simple summary of the tests so far.  True for pass, false for fail.
This is a logical pass/fail, so todos are passes.

Of course, test #1 is $tests[0], etc...


=item B<details>

    my @tests = $Test->details;

Like C<summary()>, but with a lot more detail.

    $tests[$test_num - 1] =
            { 'ok'       => is the test considered a pass?
              actual_ok  => did it literally say 'ok'?
              name       => name of the test (if any)
              type       => type of test (if any, see below).
              reason     => reason for the above (if any)
            };

'ok' is true if Test::Harness will consider the test to be a pass.

'actual_ok' is a reflection of whether or not the test literally
printed 'ok' or 'not ok'.  This is for examining the result of 'todo'
tests.

'name' is the name of the test.

'type' indicates if it was a special test.  Normal tests have a type
of ''.  Type can be one of the following:

    skip        see skip()
    todo        see todo()
    todo_skip   see todo_skip()
    unknown     see below

Sometimes the Test::Builder test counter is incremented without it
printing any test output, for example, when C<current_test()> is changed.
In these cases, Test::Builder doesn't know the result of the test, so
its type is 'unknown'.  These details for these tests are filled in.
They are considered ok, but the name and actual_ok is left C<undef>.

For example "not ok 23 - hole count # TODO insufficient donuts" would
result in this structure:

    $tests[22] =    # 23 - 1, since arrays start from 0.
      { ok        => 1,   # logically, the test passed since its todo
        actual_ok => 0,   # in absolute terms, it failed
        name      => 'hole count',
        type      => 'todo',
        reason    => 'insufficient donuts'
      };


=item B<todo>

    my $todo_reason = $Test->todo;
    my $todo_reason = $Test->todo($pack);

If the current tests are considered "TODO" it will return the reason,
if any.  This reason can come from a C<$TODO> variable or the last call
to C<todo_start()>.

Since a TODO test does not need a reason, this function can return an
empty string even when inside a TODO block.  Use C<< $Test->in_todo >>
to determine if you are currently inside a TODO block.

C<todo()> is about finding the right package to look for C<$TODO> in.  It's
pretty good at guessing the right package to look at.  It first looks for
the caller based on C<$Level + 1>, since C<todo()> is usually called inside
a test function.  As a last resort it will use C<exported_to()>.

Sometimes there is some confusion about where C<todo()> should be looking
for the C<$TODO> variable.  If you want to be sure, tell it explicitly
what $pack to use.

=item B<find_TODO>

    my $todo_reason = $Test->find_TODO();
    my $todo_reason = $Test->find_TODO($pack);

Like C<todo()> but only returns the value of C<$TODO> ignoring
C<todo_start()>.

Can also be used to set C<$TODO> to a new value while returning the
old value:

    my $old_reason = $Test->find_TODO($pack, 1, $new_reason);

=item B<in_todo>

    my $in_todo = $Test->in_todo;

Returns true if the test is currently inside a TODO block.

=item B<todo_start>

    $Test->todo_start();
    $Test->todo_start($message);

This method allows you declare all subsequent tests as TODO tests, up until
the C<todo_end> method has been called.

The C<TODO:> and C<$TODO> syntax is generally pretty good about figuring out
whether or not we're in a TODO test.  However, often we find that this is not
possible to determine (such as when we want to use C<$TODO> but
the tests are being executed in other packages which can't be inferred
beforehand).

Note that you can use this to nest "todo" tests

 $Test->todo_start('working on this');
 # lots of code
 $Test->todo_start('working on that');
 # more code
 $Test->todo_end;
 $Test->todo_end;

This is generally not recommended, but large testing systems often have weird
internal needs.

We've tried to make this also work with the TODO: syntax, but it's not
guaranteed and its use is also discouraged:

 TODO: {
     local $TODO = 'We have work to do!';
     $Test->todo_start('working on this');
     # lots of code
     $Test->todo_start('working on that');
     # more code
     $Test->todo_end;
     $Test->todo_end;
 }

Pick one style or another of "TODO" to be on the safe side.


=item C<todo_end>

 $Test->todo_end;

Stops running tests as "TODO" tests.  This method is fatal if called without a
preceding C<todo_start> method call.

=item B<caller>

    my $package = $Test->caller;
    my($pack, $file, $line) = $Test->caller;
    my($pack, $file, $line) = $Test->caller($height);

Like the normal C<caller()>, except it reports according to your C<level()>.

C<$height> will be added to the C<level()>.

If C<caller()> winds up off the top of the stack it report the highest context.

=back

=head1 EXIT CODES

If all your tests passed, Test::Builder will exit with zero (which is
normal).  If anything failed it will exit with how many failed.  If
you run less (or more) tests than you planned, the missing (or extras)
will be considered failures.  If no tests were ever run Test::Builder
will throw a warning and exit with 255.  If the test died, even after
having successfully completed all its tests, it will still be
considered a failure and will exit with 255.

So the exit codes are...

    0                   all tests successful
    255                 test died or all passed but wrong # of tests run
    any other number    how many failed (including missing or extras)

If you fail more than 254 tests, it will be reported as 254.

=head1 THREADS

In perl 5.8.1 and later, Test::Builder is thread-safe.  The test
number is shared amongst all threads.  This means if one thread sets
the test number using C<current_test()> they will all be effected.

While versions earlier than 5.8.1 had threads they contain too many
bugs to support.

Test::Builder is only thread-aware if threads.pm is loaded I<before>
Test::Builder.

=head1 MEMORY

An informative hash, accessible via C<details()>, is stored for each
test you perform.  So memory usage will scale linearly with each test
run. Although this is not a problem for most test suites, it can
become an issue if you do large (hundred thousands to million)
combinatorics tests in the same run.

In such cases, you are advised to either split the test file into smaller
ones, or use a reverse approach, doing "normal" (code) compares and
triggering C<fail()> should anything go unexpected.

Future versions of Test::Builder will have a way to turn history off.


=head1 EXAMPLES

CPAN can provide the best examples.  L<Test::Simple>, L<Test::More>,
L<Test::Exception> and L<Test::Differences> all use Test::Builder.

=head1 SEE ALSO

L<Test::Simple>, L<Test::More>, L<Test::Harness>

=head1 AUTHORS

Original code by chromatic, maintained by Michael G Schwern
E<lt>schwern@pobox.comE<gt>

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2002-2008 by chromatic E<lt>chromatic@wgz.orgE<gt> and
                       Michael G Schwern E<lt>schwern@pobox.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://www.perl.com/perl/misc/Artistic.html>
