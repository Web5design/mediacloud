use strict;
use warnings;
use Test::NoWarnings;
use Test::More tests => 3 + 1;

BEGIN { use_ok 'Catalyst::Test', 'MediaWords' }
BEGIN { use_ok 'MediaWords::Controller::Media' }

ok( request( '/media/list' )->is_success, 'Request should succeed' );
