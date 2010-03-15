package Hailo::Storage::DBD;
use 5.010;
use Any::Moose;
use Any::Moose 'X::Types::'.any_moose() => [qw<ArrayRef HashRef Int Str Bool>];
BEGIN {
    return unless Any::Moose::moose_is_preferred();
    require MooseX::StrictConstructor;
    MooseX::StrictConstructor->import;
}
use DBI;
use Hailo::Storage::Schema;
use List::Util qw<first shuffle>;
use List::MoreUtils qw<uniq>;
use Template;
use namespace::clean -except => 'meta';

has dbd => (
    isa           => Str,
    is            => 'ro',
    lazy_build    => 1,
    documentation => "The DBD::* driver we're using",
);

has dbd_options => (
    isa           => HashRef,
    is            => 'ro',
    lazy_build    => 1,
    documentation => 'Options passed as the last argument to DBI->connect()',
);

sub _build_dbd_options {
    my ($self) = @_;
    return {
        RaiseError => 1
    };
}

has dbh => (
    isa           => 'DBI::db',
    is            => 'ro',
    lazy_build    => 1,
    documentation => 'Our DBD object',
);

sub _build_dbh {
    my ($self) = @_;
    my $dbd_options = $self->dbi_options;

    return DBI->connect($self->dbi_options);
};

has schema => (
    isa => 'Hailo::Storage::Schema',
    is => 'ro',
    lazy_build => 1,
    documentation => "A Hailo::Storage::Schema instance of DBIx::Class",
);

sub _build_schema {
    my ($self) = @_;

    my $schema = Hailo::Storage::Schema->connect(
        sub { $self->dbh },
        # See http://search.cpan.org/~ribasushi/DBIx-Class-0.08120/lib/DBIx/Class/Storage/DBI.pm#DBIx::Class_specific_connection_attributes
        {},
    );

    return $schema;
}

has dbi_options => (
    isa           => ArrayRef,
    is            => 'ro',
    auto_deref    => 1,
    lazy_build    => 1,
    documentation => 'Options passed to DBI->connect()',
);

sub _build_dbi_options {
    my ($self) = @_;
    my $dbd = $self->dbd;
    my $dbd_options = $self->dbd_options;
    my $db = $self->brain // '';

    my @options = (
        "dbi:$dbd:dbname=$db",
        '',
        '',
        $dbd_options,
    );

    return \@options;
}

has _engaged => (
    isa           => Bool,
    is            => 'rw',
    default       => 0,
    documentation => 'Have we done setup work to get this database going?',
);

has _boundary_token_id => (
    isa => Int,
    is  => 'rw',
);

# bootstrap the database
sub _engage {
    my ($self) = @_;

    for (0 .. $self->order - 1) {
        Hailo::Storage::Schema::Result::Expr->add_tokenN_id($_) ;
    }

    if ($self->_exists_db) {
        my $schema =  $self->schema;

        # SELECT text FROM info WHERE attribute = 'markov_order';
        my $res = $schema->resultset('Info')->find(
            { attribute => 'markov_order' },
            { columns => [ 'text' ] },
        );
        $self->order($res->text);

        my $token_id = $self->_add_token(0, '');
        $self->_boundary_token_id($token_id);
    }
    else {
        $self->_create_db();

        my $schema = $self->schema;
        # INSERT INTO info (attribute, text) VALUES ('markov_order', ?);
        $schema->resultset('Info')->create({
            attribute => 'markov_order',
            text      => $self->order,
        });

        # INSERT INTO token (spacing, text, count) VALUES (?, ?, 0)
        my $rs = $schema->resultset('Token')->create({
            spacing => 0,
            text    => '',
            count   => 0,
        });
        $self->_boundary_token_id($rs->id);
    }

    $self->_engaged(1);

    return;
}

sub start_training {
    my ($self) = @_;
    $self->_engage() if !$self->_engaged;
    $self->start_learning();
    return;
}

sub stop_training {
    my ($self) = @_;
    $self->stop_learning();
    return;
}

sub start_learning {
    my ($self) = @_;
    $self->_engage() if !$self->_engaged;

    # start a transaction
    $self->dbh->begin_work;
    return;
}

sub stop_learning {
    my ($self) = @_;
    # finish a transaction
    $self->dbh->commit;
    return;
}

sub _create_db {
    my ($self) = @_;
    my @statements = $self->_get_create_db_sql;

    for (@statements) {
        $self->dbh->do($_);
    }

    return;
}

sub _get_create_db_sql {
    my ($self) = @_;
    my $sql;

    my @create = $self->table_sql;

    for my $template (@create) {
        Template->new->process(
            $template,
            {
                columns => join(', ', map { "token${_}_id" } 0 .. $self->order-1),
                orders  => [ 0 .. $self->order-1 ],
                dbd     => $self->dbd,
            },
            \$sql,
        );
    }

    return ($sql =~ /\s*(.*?);/gs);
}

# return some statistics
sub totals {
    my ($self) = @_;
    $self->_engage() if !$self->_engaged;
    my $schema = $self->schema;

    # SELECT COUNT(*) from $table;
    my $token = $schema->resultset("Token")->count - 1,
    my $expr  = $schema->resultset("Expr")->count // 0,
    my $prev  = $schema->resultset("PrevToken")->count // 0,
    my $next  = $schema->resultset("NextToken")->count // 0;

    return $token, $expr, $prev, $next;
}

## no critic (Subroutines::ProhibitExcessComplexity)
sub make_reply {
    my $self = shift;
    my $tokens = shift // [];
    $self->_engage() if !$self->_engaged;
    my $order = $self->order;
    my $schema = $self->schema;

    # we will favor these tokens when making the reply
    my @key_tokens = @$tokens;

    # shuffle the tokens and discard half of them
    @key_tokens = do {
        my $i = 0;
        grep { $i++ % 2 == 0 } shuffle(@key_tokens);
    };

    my (@key_ids, %token_cache);
    for my $token_info (@key_tokens) {
        my $text = $token_info->[1];
        my $info = $self->_token_similar($text);
        next if !defined $info;
        my ($id, $spacing) = ($info->id, $info->spacing);
        next if !defined $id;
        push @key_ids, $id;
        next if exists $token_cache{$id};
        $token_cache{$id} = [$spacing, $text];
    }

    # sort the rest by rareness
    @key_ids = $self->_find_rare_tokens(\@key_ids, 2);

    # get the middle expression
    my $seed_token_id = shift @key_ids;
    my ($orig_expr_id, @token_ids) = $self->_random_expr($seed_token_id);
    return if !defined $orig_expr_id; # we don't know any expressions yet

    # remove key tokens we're already using
    @key_ids = grep { my $used = $_; !first { $_ == $used } @token_ids } @key_ids;

    my $repeat_limit = $self->repeat_limit;
    my $expr_id = $orig_expr_id;

    # construct the end of the reply
    my $i = 0;
    while (1) {
        if (($i % $order) == 0 and
            (($i >= $repeat_limit * 3) ||
             ($i >= $repeat_limit and uniq(@token_ids) <= $order))) {
            last;
        }
        my $next_id = $self->_pos_token('next', $expr_id, \@key_ids);
        last if $next_id eq $self->_boundary_token_id;
        push @token_ids, $next_id;
        $expr_id = $self->_expr_id([@token_ids[-$order..-1]]);
    } continue {
        $i++;
    }

    $expr_id = $orig_expr_id;

    # construct the beginning of the reply
    $i = 0; while (1) {
        if (($i % $order) == 0 and
            (($i >= $repeat_limit * 3) ||
             ($i >= $repeat_limit and uniq(@token_ids) <= $order))) {
            last;
        }
        my $prev_id = $self->_pos_token('prev', $expr_id, \@key_ids);
        last if $prev_id eq $self->_boundary_token_id;
        unshift @token_ids, $prev_id;
        $expr_id = $self->_expr_id([@token_ids[0..$order-1]]);
    } continue {
        $i++;
    }

    # translate token ids to token spacing/text
    my @reply;
    for my $id (@token_ids) {
        # XXX: This cache can probably be implemented in terms of DBIx::Class caching
        if (!exists $token_cache{$id}) {
            # SELECT spacing, text FROM token WHERE id = ?;
            my $token_info = $schema->resultset('Token')->find(
                { id => $id },
                { columns => [ qw/ spacing text / ] },
            );
            $token_cache{$id} = [ $token_info->spacing, $token_info->text ];
        }
        push @reply, $token_cache{$id};
    }
    return \@reply;
}

sub learn_tokens {
    my ($self, $tokens) = @_;
    my $order = $self->order;
    my $schema = $self->schema;
    my %token_cache;

    for my $token (@$tokens) {
        my $key = join '', @$token;
        next if exists $token_cache{$key};
        $token_cache{$key} = $self->_token_id_add($token);
    }

    # process every expression of length $order
    for my $i (0 .. @$tokens - $order) {
        my @expr = map { $token_cache{ join('', @{ $tokens->[$_] }) } } $i .. $i+$order-1;
        my $expr_id = $self->_expr_id(\@expr);

        if (!defined $expr_id) {
            $expr_id = $self->_add_expr(\@expr);

            for (uniq(@expr)) {
                # UPDATE token SET count = count + 1 WHERE id = ?;
                $schema->resultset("Token")->search( { id => $_ }, undef )->update({
                    count => \'count + 1'
                });
            }
        }

        # add link to next token for this expression, if any
        if ($i < @$tokens - $order) {
            my $next_id = $token_cache{ join('', @{ $tokens->[$i+$order] }) };
            $self->_inc_link('NextToken', $expr_id, $next_id);
        }

        # add link to previous token for this expression, if any
        if ($i > 0) {
            my $prev_id = $token_cache{ join('', @{ $tokens->[$i-1] }) };
            $self->_inc_link('PrevToken', $expr_id, $prev_id);
        }

        # add links to boundary token if appropriate
        my $b = $self->_boundary_token_id;
        $self->_inc_link('PrevToken', $expr_id, $b) if $i == 0;
        $self->_inc_link('NextToken', $expr_id, $b) if $i == @$tokens-$order;
    }

    return;
}

# sort token ids based on how rare they are
sub _find_rare_tokens {
    my ($self, $token_ids, $min) = @_;
    return if !@$token_ids;
    my $schema = $self->schema;

    my %links;
    for my $id (@$token_ids) {
        next if exists $links{$id};
        my $res = $schema->resultset('Token')->find(
            { id => $id },
            { columns => [ 'count' ] },
        );
        $links{$id} = $res->count;
    }

    # remove tokens which are too rare
    my @ids = grep { $links{$_} >= $min } @$token_ids;

    @ids = sort { $links{$a} <=> $links{$b} } @ids;

    return @ids;
}

# increase the link weight between an expression and a token
sub _inc_link {
    my ($self, $type, $expr_id, $token_id) = @_;
    my $schema = $self->schema;
    my %cols = (
        expr_id  => $expr_id,
        token_id => $token_id,
    );

    # SELECT count FROM [% table %] WHERE expr_id = ? AND token_id = ?;
    my $rs = $schema->resultset($type)->find(
        {
            expr_id  => $expr_id,
            token_id => $token_id,
        },
        { columns => 'count' },
    );

    given ($rs) {
        when (defined) {
            # UPDATE [% table %] SET count = count + 1 WHERE expr_id = ? AND token_id = ?
            $schema->resultset($type)->search(
                \%cols, {}
            )->update({
                count => \'count + 1'
            });
        }
        default {
            # INSERT INTO [% table %] (expr_id, token_id, count) VALUES (?, ?, 1);
            $schema->resultset($type)->create({
                %cols,
                count => 1,
            });
        }
    }

    return;
}

# add new expression to the database
sub _add_expr {
    my ($self, $token_ids) = @_;
    my $schema = $self->schema;

    my %columns;
    for my $i (0 .. $#$token_ids) {
        $columns{"token${i}_id"} = $token_ids->[$i];
    }

    # INSERT INTO expr ([% columns %]) VALUES ([% ids %])
    my $rs = $schema->resultset('Expr')->create(\%columns);

    return $rs->id;
}

# look up an expression id based on tokens
sub _expr_id {
    my ($self, $tokens) = @_;
    my $schema = $self->schema;

    my %where;
    for my $i (0 .. $#$tokens) {
        $where{"token${i}_id"} = $tokens->[$i];
    }
    # SELECT id FROM expr WHERE
    # [% FOREACH i IN orders %]
    #     token[% i %]_id = ? [% UNLESS loop.last %] AND [% END %]
    # [% END %]
    my $res = $schema->resultset('Expr')->find(
        \%where,
        { columns => 'id' },
    );
    return unless $res;
    return $res->id;
}

# return token id if the token exists
sub _token_id {
    my ($self, $token_info) = @_;
    my $schema = $self->schema;

    # SELECT id FROM token WHERE spacing = ? AND text = ?;
    my $token_id = $schema->resultset('Token')->find(
        {
            spacing => $token_info->[0],
            text    => $token_info->[1],
        },
        { columns => [ 'id' ] },
    );
    return if !defined $token_id;
    return $token_id->id;
}

# get token id (adding the token if it doesn't exist)
sub _token_id_add {
    my ($self, $token_info) = @_;

    my $token_id = $self->_token_id($token_info);
    $token_id = $self->_add_token($token_info) if !defined $token_id;
    return $token_id;
}

# return all tokens (regardless of spacing) that consist of this text
sub _token_similar {
    my ($self, $token_text) = @_;
    my $schema = $self->schema;

    # SELECT id, spacing FROM token WHERE text = ? ORDER BY RANDOM() LIMIT 1
    return $schema->resultset('Token')->search(
        { text => $token_text },
        { columns => [ qw/id spacing/ ] }
    )->rand->single;
}

# add a new token and return its id
sub _add_token {
    my ($self, $token_info) = @_;
    my $schema = $self->schema;

    my $rs = $schema->resultset('Token')->create({
        spacing => $token_info->[0],
        text    => $token_info->[1],
        count   => 0,
    });
    return $rs->id;
}

# return a random expression containing the given token
sub _random_expr {
    my ($self, $token_id) = @_;
    my $schema = $self->schema;

    my $expr;

    my @columns = ('id', map { "token${_}_id" } 0 .. $self->order-1);

    if (!defined $token_id) {
        my $rand;

        given ($self->dbd) {
            when ('Pg')    { $rand = '(random()*id+1)::int' }
            when ('mysql') { $rand = '(abs(rand()) % (SELECT max(id) FROM expr))' }
            when ('SQLite') { $rand = '(abs(random()) % (SELECT max(id) FROM expr))' }
            default         { die "Hailo doesn't support your $_ database yet" }
        }

        # SELECT * from expr WHERE id >= (abs(random()) % (SELECT max(id) FROM expr)) LIMIT 1;
        my $rs = $schema->resultset('Expr')->search(
            { id => { '>=', \$rand } },
            {
                columns => \@columns,
                result_class => 'DBIx::Class::ResultClass::HashRefInflator',
                rows => 1,
            }
        )->single;

        $expr = [ map { $rs->{$_} } @columns ] if $rs;
    }
    else {
        # try the positions in a random order
        for my $pos (shuffle 0 .. $self->order-1) {
            # SELECT * FROM expr WHERE [% column %] = ? ORDER BY RANDOM() LIMIT 1;
            my $rs = $schema->resultset('Expr')->search(
                { "token${pos}_id" => $token_id },
                { columns => \@columns }
            )->rand->single;

            # get a random expression which includes the token at this position
            $expr = [ map { $rs->$_ } @columns ] if $rs;
            last if defined $expr;
        }
    }

    return if !defined $expr;
    return @$expr;
}

# return a new next/previous token
sub _pos_token {
    my ($self, $pos, $expr_id, $key_tokens) = @_;
    my $schema = $self->schema;

    # SELECT token_id, count FROM [% table %] WHERE expr_id = ?;
    my @rs = $schema->resultset(ucfirst($pos).'Token')->search(
        { expr_id => $expr_id },
        { columns => [ qw/ token_id count / ] },
    )->all();

    # XXX: Can I make DBIx::Class do what fetchall_hashref('token_id')
    # did automatically? DBIx::Class::ResultClass::HashRefInflator
    # only does it on a per-row basis.
    my $pos_tokens = {};
    for my $row (@rs) {
        $pos_tokens->{ $row->token_id } = {
            token_id => $row->token_id,
            count    => $row->count,
        };
    }

    if (defined $key_tokens) {
        for my $i (0 .. $#{ $key_tokens }) {
            next if !exists $pos_tokens->{ @$key_tokens[$i] };
            return splice @$key_tokens, $i, 1;
        }
    }

    my @novel_tokens;
    for my $token (keys %$pos_tokens) {
        push @novel_tokens, ($token) x $pos_tokens->{$token}{count};
    }
    return $novel_tokens[rand @novel_tokens];
}

__PACKAGE__->meta->make_immutable;

=encoding utf8

=head1 NAME

Hailo::Storage::DBD - A base class for L<Hailo> DBD
L<storage|Hailo::Role::Storage> backends

=head1 METHODS

The following methods must to be implemented by subclasses:

=head2 C<_build_dbd>

Should return the name of the database driver (e.g. 'SQLite') which will be
passed to L<DBI|DBI>.

=head2 C<_build_dbd_options>

Subclasses can override this method to add options of their own. E.g:

    override _build_dbd_options => sub {
        return {
            %{ super() },
            sqlite_unicode => 1,
        };
    };

=head2 C<_exists_db>

Should return a true value if the database has already been created.

=head1 AUTHOR

E<AElig>var ArnfjE<ouml>rE<eth> Bjarmason <avar@cpan.org>

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=head1 LICENSE AND COPYRIGHT

Copyright 2010 E<AElig>var ArnfjE<ouml>rE<eth> Bjarmason and
Hinrik E<Ouml>rn SigurE<eth>sson

This program is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

sub table_sql {
    my ($self) = @_;

    my $info = <<'TABLE';
CREATE TABLE info (
    attribute [% SWITCH dbd %]
                  [% CASE 'mysql' %]TEXT NOT NULL,
                  [% CASE DEFAULT %]TEXT NOT NULL PRIMARY KEY,
              [% END %]
    text      TEXT NOT NULL
);
TABLE
    my $token = <<'TABLE';
CREATE TABLE token (
    id   [% SWITCH dbd %]
            [% CASE 'Pg'    %]SERIAL UNIQUE,
            [% CASE 'mysql' %]INTEGER PRIMARY KEY AUTO_INCREMENT,
            [% CASE DEFAULT %]INTEGER PRIMARY KEY AUTOINCREMENT,
         [% END %]
    spacing INTEGER NOT NULL,
    text [% IF dbd == 'mysql' %] VARCHAR(255) [% ELSE %] TEXT [% END %] NOT NULL,
    count INTEGER NOT NULL
);
TABLE
        my $expr = <<'TABLE';
CREATE TABLE expr (
    id  [% SWITCH dbd %]
            [% CASE 'Pg'    %]SERIAL UNIQUE
            [% CASE 'mysql' %]INTEGER PRIMARY KEY AUTO_INCREMENT
            [% CASE DEFAULT %]INTEGER PRIMARY KEY AUTOINCREMENT
        [% END %],
[% FOREACH i IN orders %]
    token[% i %]_id INTEGER NOT NULL REFERENCES token (id)[% UNLESS loop.last %],[% END %]
[% END %]
);
TABLE
        my $next_token = <<'TABLE';
CREATE TABLE next_token (
    id       [% SWITCH dbd %]
                 [% CASE 'Pg'    %]SERIAL UNIQUE,
                 [% CASE 'mysql' %]INTEGER PRIMARY KEY AUTO_INCREMENT,
                 [% CASE DEFAULT %]INTEGER PRIMARY KEY AUTOINCREMENT,
             [% END %]
    expr_id  INTEGER NOT NULL REFERENCES expr (id),
    token_id INTEGER NOT NULL REFERENCES token (id),
    count    INTEGER NOT NULL
);
TABLE
        my $prev_token = <<'TABLE';
CREATE TABLE prev_token (
    id       [% SWITCH dbd %]
                 [% CASE 'Pg'    %]SERIAL UNIQUE,
                 [% CASE 'mysql' %]INTEGER PRIMARY KEY AUTO_INCREMENT,
                 [% CASE DEFAULT %]INTEGER PRIMARY KEY AUTOINCREMENT,
             [% END %]
    expr_id  INTEGER NOT NULL REFERENCES expr (id),
    token_id INTEGER NOT NULL REFERENCES token (id),
    count    INTEGER NOT NULL
);
TABLE
        my $indexes = <<'TABLE';
CREATE INDEX token_text on token (text);
[% FOREACH i IN orders %]
    CREATE INDEX expr_token[% i %]_id on expr (token[% i %]_id);
[% END %]
CREATE INDEX expr_token_ids on expr ([% columns %]);
CREATE INDEX next_token_expr_id ON next_token (expr_id);
CREATE INDEX prev_token_expr_id ON prev_token (expr_id);
TABLE
    return (\$info, \$token, \$expr, \$next_token, \$prev_token, \$indexes);
}
