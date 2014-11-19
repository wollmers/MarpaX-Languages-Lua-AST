# Copyright 2014 Ruslan Shvedov

# Extend Lua 5.1 parser from MarpaX::Languages::Lua::AST
# with grammar rules and transpile them to pure lua

package MarpaX::Languages::Lua::LUIF;

use v5.14.2;
use strict;
use warnings;

use MarpaX::Languages::Lua::AST;

use Data::Dumper;
$Data::Dumper::Indent = 1;
$Data::Dumper::Terse = 1;
$Data::Dumper::Deepcopy = 1;

my $bnf = q{

## BNF statement
stat ::= BNF

BNF ::= <BNF rule>+

exp ::= grammarexp

grammarexp ::= <grammar> grambody

grambody ::= <left paren> parlist <right paren> block <end>
grambody ::= <left paren> <right paren> block <end>

# There is only one BNF statement,
# combining priorities, sequences, and alternation
<BNF rule> ::= lhs '::=' <prioritized alternatives>
<prioritized alternatives> ::= <prioritized alternative>+ separator => <double bar>
<prioritized alternative> ::= <alternative>+ separator => <bar>
<alternative> ::= rhs | rhs ',' <alternative fields>
<alternative fields> ::= <alternative field>+ separator => comma
<alternative field> ::= field | action
action ::= 'action' '(' <action parlist> ')' block <end>
<action parlist> ::= <symbol parameter> | <action parlist> ',' <symbol parameter>
<symbol parameter> ::= <named RH symbol>
  | <named RH symbol> '[' <nonnegative integer> ']'
  | <named RH symbol> '[]'

<named RH symbol> ::= <named symbol>
lhs ::= <named symbol>

<double bar> ~ '||'
bar ~ '|'
comma ~ ','

rhs ::= <RH atom>+
<RH atom> ::=
     '[]' # for empty symbol
   | <separated sequence>
   | <named symbol>
   | '(' alternative ')'

# The sequence notation is extended to counted sequences,
# and a separator notation adopted from Perl 6 is used

<named symbol> ::= <symbol name>
<separated sequence> ::=
      sequence
| sequence '%' separator # proper separation
| sequence '%%' separator # Perl separation

separator ::= <named symbol>

sequence ::=
     <named symbol> '+'
   | <named symbol> '*'
   | <named symbol> '?'
   | <named symbol> '*' <nonnegative integer> '..' <nonnegative integer>
   | <named symbol> '*' <nonnegative integer> '..' '*'

# symbol name is any valid Lua name, plus those with
# non-initial hyphens
# TODO: add angle bracket variation
#<symbol name> ~ [a-zA-Z_] <symbol name chars>
#<symbol name chars> ~ [-\w]*
<symbol name> ::= Name

#<nonnegative integer> ~ [\d]+
<nonnegative integer> ::= Number

# <symbol name>, <symbol name chars>, <nonnegative integer> rules
# are commented out from Jeffrey Kegler's BNF because
# MarpaX::Languages::Lua::AST::extend() doesn't support character classes.
# For the moment, suitable tokens from Lua grammar (Name and Number) are used instead
# TODO: support charclasses per https://gist.github.com/rns/2ae390a2c7d235687287

## end of BNF statement spec
};

# [ lhs, [ rhs ], adverbs
sub bnf_ast_traverse{
    my ($parser, $ast) = @_;
    if (ref $ast){
        my ($node_id, @children) = @$ast;
        if ($node_id eq 'stat'){
            bnf_ast_traverse($parser, @children);
        }
        elsif ($node_id eq 'BNF'){
#            say "$node_id: ", Dumper \@children;
            my (undef, $name, $rules) = @children;
            return {
                rules => [ map { bnf_ast_traverse( $parser, $_ ) } @children ]
            }
        }
        elsif ($node_id eq 'BNF rule'){
#            say "$node_id: ", Dumper \@children;
            my ($lhs, $op, $alternatives) = @children;
            return {
                lhs => bnf_ast_traverse( $parser, $lhs ),
                rhs => bnf_ast_traverse( $parser, $alternatives ),
            }
        }
        elsif ( $node_id eq 'lhs' ){
            return $children[0]->[1]->[1]->[1];
        }
        elsif ( $node_id eq 'prioritized alternatives' ){
#            say "$node_id: ", Dumper \@children;
            return {
                'prioritized alternatives' => [ map { bnf_ast_traverse( $parser, $_ ) } @children ]
            }
        }
        elsif ( $node_id eq 'prioritized alternative' ){
#            say "$node_id: ", Dumper \@children;
            return {
                'prioritized alternative' => [
                    map { bnf_ast_traverse( $parser, $_ ) } @children
                ]
            }
        }
        elsif ( $node_id eq 'alternative' ){
#            say "$node_id: ", Dumper \@children;
            return [ map { bnf_ast_traverse( $parser, $_ ) } grep { $_->[0] ne 'comma' } @children ];
        }
        elsif ( $node_id eq 'separated sequence' ){
#            say "$node_id: ", Dumper \@children;
            my ($sequence, $separator_sign, $separator_symbol) = @children;
            my $symbol           = $sequence->[1]->[1]->[1]->[1];
            my $quantifier       = $sequence->[2]->[1];
               $separator_sign   = $separator_sign->[1];
               $separator_symbol = $separator_symbol->[1]->[1]->[1]->[1];
            return {
                item => $symbol,
                quantifier => $quantifier,
                separator => $separator_symbol,
                proper => $separator_sign eq '%' ? 1 : 0
            };
        }
        elsif ( $node_id eq 'rhs'){
#            say "$node_id: ", Dumper \@children;
            return map { bnf_ast_traverse( $parser, $_ ) } @children
        }
        elsif ( $node_id eq 'RH atom'){
#            say "$node_id: ", Dumper \@children;
            return map { bnf_ast_traverse( $parser, $_ ) } @children
        }
        elsif ( $node_id eq 'action'){
#            say "$node_id: ", Dumper \@children;
            $children[0]->[1] = 'function'; # action becomes function in lua
            my $action = join ' ', map { bnf_ast_traverse( $parser, $_ ) } @children;
            $action =~ s/\(\s+/(/;  # these will apply to the first occurence
            $action =~ s/\s+\)/)/;  # that is the action parlist
            $action =~ s/\s+,/,/;
            $action =~ s/\)\s+/) /;
            return { action => $action };
        }
        elsif ($node_id eq 'alternative fields'){
            return {
                fields => map { bnf_ast_traverse( $parser, $_ ) } @children
            }
        }
        elsif ($node_id eq 'field'){
            return $parser->fmt($ast); # this is pure lua
        }
        elsif ( $node_id eq 'action parlist'){
#            say "$node_id: ", Dumper \@children;
            return join ' ', map { bnf_ast_traverse( $parser, $_ ) } @children;
        }
        elsif ( $node_id eq 'block'){
            return $parser->fmt($ast); # this is pure lua too
        }
        return bnf_ast_traverse( $parser, $_ ) for @children;
    }
    else{
#        say "unhandled scalar $ast";
        return $ast;
    }
}

my $default_grammar; # default grammar was processed
my $explicit_grammar; # explicit grammar was processed

sub bnf2luatable {
    my ($parser, $ast, $context) = @_;
#    say "ast:", Dumper $ast;
#    say Dumper $bnf;
    my ($indent, $indent_level) = map { $context->{$_} } qw { indent indent_level };

    # gather data
    my $bnf = bnf_ast_traverse($parser, $ast);
#    say "BNF intermediate form:", Dumper $bnf;

    # render bnf rules data as lua tables
    my ($lua_bnf_start, $lua_bnf_end);
    if ($explicit_grammar){
        die "Default grammar can't follow explicit grammar and in a single Lua script" if $explicit_grammar and $default_grammar;
        $lua_bnf_start = "\n";
        $lua_bnf_end = '';
    }
    else{ # default grammar
        $lua_bnf_start = "\n" . $indent x $indent_level . "default_grammar = {\n";
        $lua_bnf_end = $indent x $indent_level . "}";
        # rules in the default grammar need more indent
        $indent_level++;
        $default_grammar = 1;
    }

    my $lua_bnf = $lua_bnf_start;

    my $rules = $bnf->{rules};
    for my $rule (@$rules){

        my $lhs = $rule->{lhs};
        my $priority;
    #    say "# rule:\nlhs: ", $lhs;
        # prioritized_alternatives are joined with double bar ||, loosen precedence
        my $prioritized_alternatives = $rule->{rhs}->{"prioritized alternatives"};
        for my $pa_ix ( 0 .. @{ $prioritized_alternatives } - 1){
            my $pa = $prioritized_alternatives->[$pa_ix];
            my @alternatives = $pa->{"prioritized alternative"};
            # alternatives are joined with bar |, same precedence
            for my $alternative (@alternatives){
    #            warn "alternative:\n", Dumper $alternative;
                for my $rhs_ix ( 0 .. @$alternative - 1){
                    my $rhs = $alternative->[$rhs_ix];
    #                warn "rhs:\n", Dumper $rhs;
                    # rhs layout
                    # [
                    #   [ rhs_sym1, rhs_sym2, ..., { fields } ]
                    #   or
                    #   [ { rhs_as_hash_ref }, { fields } ]
                    # ]
                    # first extract fields, if any
                    my $fields = {};
                    $fields = (pop @$rhs)->{fields} if @$rhs > 1 and ref $rhs->[-1] eq "HASH";
                    # then set rhs to its hash ref rhs
                    $rhs = $rhs->[0] if ref $rhs->[0] eq "HASH";
                    # add array ref rule
                    my $lua_bnf_rule;
                    if (ref $rhs eq "ARRAY"){
                        $lua_bnf_rule =
                            $indent x $indent_level . "$lhs = { " .
                            join(', ', map { "'$_'" } @$rhs );
                    }
                    # add hash ref rule
                    elsif (ref $rhs eq "HASH"){
                        # separated sequence
                        if ( exists $rhs->{quantifier} ){
                            # sequence item symbol
                            my $item = $rhs->{item};
                            # other adverbs go to fields
                            for my $k ( qw{ quantifier separator proper } ){
                                my $v = $k eq 'proper' ? $rhs->{$k} : "'$rhs->{$k}'";
                                $fields->{$k} = $v;
                            }
                            $lua_bnf_rule =
                                $indent x $indent_level . "$lhs = { " .
                                "'" . $item . "'";
                        }
                        else{
                            warn "bnf2luatable: unknown rhs type: " . Dumper $rhs;
                        }
                    }
                    else{
                        warn "bnf2luatable: unknown rhs type $rhs.";
                    }
#                    warn $priority if $priority;
                    $fields->{priority} = "'$priority'" if $priority;
                    $lua_bnf .= $lua_bnf_rule;
#                    warn $lua_bnf_rule;
                    $priority = '|';
#                        warn $priority if $rhs_ix < @$alternative - 1;
                    # add fields, if any
                    if (keys %$fields){
    #                    warn "fields: ", Dumper $fields;
                        $lua_bnf .=
                            ",\n" .
                            $indent x ($indent_level + 1) . "fields = {\n" .
                            $indent x ($indent_level + 2)  .
                            join (
                                ( ",\n" . $indent x ($indent_level + 2) ),
                                map { "$_ = $fields->{$_}" } sort keys %$fields
                            ) .
                            "\n" . $indent x ($indent_level + 1) . "}\n";
                        # close the table with fields
                        $lua_bnf .=
                              $indent x $indent_level
                            . ( $default_grammar ? "},\n" : "}\n" );
                    }
                    # close the table without fields
                    else {
                        $lua_bnf .= $default_grammar ? " },\n" : " }\n"
                    }
                } ## for my $rhs (@$alternative){
                $priority = '';
            } ## for my $alternative (@alternatives){
            $priority = '||';
#            warn '||' if $pa_ix < @{ $prioritized_alternatives } - 1;
        } ## for my $pa ( @{ $prioritized_alternatives } ){
    } ## for my $rule (@$rules)
    $lua_bnf .= $lua_bnf_end;
    return $lua_bnf;
}

sub do_grammarexp{
    my ($parser, $ast, $context) = @_;
    warn "do_grammarexp: Exp/Def:", $explicit_grammar, '/', $default_grammar;
    die "Explicit grammar can't follow default grammar in a single Lua script" if $default_grammar;
#    say "# do_grammarexp\nast:", Dumper $ast;
    my $g_name = $ast->[1]->[1]->[1];
    my $g_body = $ast->[1]->[2];
    shift @$g_body; # strip node name
    pop @$g_body;   # strip 'end'
#    say "# $g_name:\n", Dumper $g_body; exit;

    my $g_block   = pop $g_body;
    my $g_parlist = $g_body;
#    say "# $g_name:\n", Dumper $g_parlist;
    my ($indent, $indent_level) = map { $context->{$_} } qw { indent indent_level };
    $explicit_grammar = 1;
    return "function()\n" . $parser->fmt($g_block) . "\nend\n";
}

our @ISA = qw(MarpaX::Languages::Lua::AST);

sub new {
    my ($class, $opts) = @_;
    my $parser = $class->SUPER::new( $opts );

    $parser->extend({
        # these rules will be incorporated into grammar source
        rules => $bnf,
        # these literals will be made tokens for external lexing
        literals => {
                '%%'      => 'Perl separation',
                '::='     => 'op declare bnf',
                '?'       => 'question',
                '[]'      => 'empty symbol',
                'action'  => 'action literal',
                'grammar' => 'grammar',
        },
        # these must return ast subtrees serialized to valid lua
        handlers => {
            BNF => \&bnf2luatable,
            grammarexp => \&do_grammarexp,
        },
    });

    return $parser;
}

sub parse {
    my ( $parser, $source, $recce_opts ) = @_;
    $default_grammar  = 0;
    $explicit_grammar = 0;
    return $parser->SUPER::parse( $source, $recce_opts );
}

1;