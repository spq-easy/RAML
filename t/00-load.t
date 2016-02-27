#!perl -T
use 5.0014;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'RAML' ) || print "Bail out!\n";
}

diag( "Testing RAML $RAML::VERSION, Perl $], $^X" );
