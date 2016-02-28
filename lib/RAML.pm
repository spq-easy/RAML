package RAML;

use 5.0014;
use Moo;
use namespace::clean;

use YAML::Syck;
use Data::Dumper; # XXX remove before shipping!

=head1 NAME

RAML - RESTful API Markup Language

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

use constant HTTP_METHODS => qw(post put patch get delete);


# Translation map for RAML spec terms to internal attribute name
# Also serves as a whitelist of supported fields
my %NAME_MAP = (
    resourceTypes => 'types',
    version       => 'version',
    title         => 'title',
    traits        => 'traits',
    baseUri       => 'base_uri',
    schemas       => 'schemas',
);

=head1 SYNOPSIS

RAML provides a full representation of a RESTful API as documented in a .raml file.
The goal is to fully load the API's specification, including loading all the
linked resources, and return an object with fully expanded resources (Endpoints).

    use RAML;

    my $api = RAML->new('api.raml');
    
    my $resources = $api->endpoints;

    foreach my $resource (@{$resources}) {
        print $resource->path; # /foo/{thing}/bar
        foreach my $endpoint ($resource->endpoints) {
            print $endpoint->method; # get
            print $endpoint->name; # get_foo_thing_bar
            print $endpoint->schema; # etc
        }
    }

=head1 ATRIBUTES

=head2 spec

The fully interpolated RAML spcification as text. Please note that as this is
re-serialized from a data structure the order of elements can not be gauranteed.

=cut
has spec => (
    is => 'lazy',
);


=head2 valid

=cut
has valid => (
    is      => 'rwp',
    default => 1,
);


=head2 version

=cut
has version => (
    is   => 'rwp',
    lazy => 1,
);


=head2 title

=cut
has title => (
    is   => 'rwp',
    lazy => 1,
);


=head2 base_uri

=cut
has base_uri => (
    is   => 'rwp',
    lazy => 1,
);


=head2 types

=cut
has types => (
    is      => 'rwp',
    builder => 1,
);


=head2 schemas

=cut
has schemas => (
    is      => 'rwp',
    builder => 1,
);


=head2 traits

=cut
has traits => (
    is      => 'rwp',
    builder => 1,
);


# PRIVATE
has _raml_file => (
    is       => 'rwp',
    required => 1,
    init_arg => 'raml',
);

has _raml_path => (
    is       => 'rwp',
    default  => '',
    init_arg => undef,
);


##
## Builders
##

sub _build_schemas { return { } }
sub _build_traits  { return { } }
sub _build_types   { return { } }

sub BUILDARGS {
    my $class = shift;
    my @args  = shift;

    # This class currently only takes one argument to new, and that is the raml
    # file to init from; if there are ever more things this accepts the one arg
    # new should still be supported.
    return { raml => $args[0] };
}


sub BUILD {
    my $self = shift;

    # TO DO: Use a CPAN file path module
    my $filename = $self->_raml_file;
    warn "== $filename\n";
    if ($filename =~ m{^(.*)/([^/]+\.raml$)}) {
        warn "=== $1, $2\n";
        $self->_set__raml_path($1);
        $self->_set__raml_file($2);
    }

    # Read in the raml specification
    open(my $raml, '<', $filename)
        or die "Unable to read .raml file $filename: $!";

    my $yaml;
    {
        local $/ = undef; # slurpy
        $yaml = <$raml>;
    }

    my $spec;
    eval { $spec = YAML::Syck::Load($yaml) };

    if ($@ || ! ref($spec) eq 'HASH') {
        die "Invalid or missing raml: $@";
    }

    $self->_process_spec($spec);
}

# Private
sub _process_spec {
    my $self = shift;
    my $spec = shift;

    # Extract the resources
    my %resources = ();
    foreach my $key (keys %{$spec}) {
        if ($key =~ m{^/}) {
            $resources{$key} = delete($spec->{$key});
        }
    }

    # Extract the known attributes
    my %attribs = ();
    while (my ($key, $name) = each %NAME_MAP) {
        $attribs{$name} = delete($spec->{$key}) if $spec->{$key};
    }

    # If there is anything left that we didn't extract, mark the schema as invalid
    if (keys %{$spec}) {
        # TBD: Store a collection of validation errors for OO access instead?
        warn "Unsupported keys remain in schema: " . join(', ', keys %{$spec});
        $self->_set_valid(0);
    }

    # Now that we have the parts broken down, start populating our attributes

    # Some things are simple
    $self->_set_version( $attribs{version} )   if $attribs{version};
    $self->_set_base_uri( $attribs{base_uri} ) if $attribs{base_uri};
    $self->_set_title( $attribs{title} )       if $attribs{title};

    # These are all collections, individual items of which may have been
    # refactored out to seperate files; make sure we've read them in if so
    foreach my $listname ( qw(schemas traits types)) {
        my $i = -1;

        foreach my $item (@{$attribs{$listname}}) {
            $i++;

            if (ref($item) ne 'HASH') {
                warn "Unsupported item type in list: $item";
                $self->_set_valid(0);
                next;
            }

            if (scalar(keys %{$item}) != 1) {
                warn "Too may elements within item: " . join(', ', keys %{$item});
                $self->_set_valid(0);
                next;
            }

            my $key = (keys %{$item})[0];
            next if ref($item->{$key}); # already is data

            # If a string, try to read it from a file
            # TO DO: Use a CPAN file path module
            my $filename = join('/', $self->_raml_path, $item->{$key});
            my $data = $self->_read_from_file($filename, 
                ($listname eq 'schemas' ? 1 : 0) # Don't try to desreialize schemas
            );

            if ($data) {
                $self->$listname->{$key} = $data;
            }
        }
    }

    # Now that we've parsed all the top level items, lets create the resource
    # objects
    foreach my $key (keys %resources) {
        $self->_compile_resource($key, $resources{$key});
    }
}

sub _read_from_file {
    my $self     = shift;
    my $filename = shift;
    my $not_raml = shift;

    open(my $source_fh, '<', $filename) or die "Unable to read $filename: $!";

    local $/ = undef; # slurpy
    my $source = <$source_fh>;

    # Schemas and such we keep as is
    return $source if $not_raml;

    # Otherwise the file contents should be more raml
    my $data;
    eval { $data = YAML::Syck::Load($source) };
    # TBD: Are the contents always suppossed to be an array or hash?!
    if ($@ || ! ref($data)) {
        warn "Problem parsing from $filename";
        $self->_set_valid(0);
        return;
    }

    return $data;
}

sub _compile_resource {
    my $self     = shift;
    my $uri      = shift;
    my $resource = shift;

    my $path = exists($resource->{parent_path})
        ? $resource->{parent_path} . $uri
        : $uri;


    # Go through the resource data and compile the parameters needed to instantiate
    # new Endpoint objects. As nested resources are discovered, set the parent path
    # within that data and call this method such that we recurse down the entire tree,
    # keeping track of parantage as we go.
    foreach my $key (keys %{$resource}) {
        if ($key =~ m{^/}) {
            $resource->{$key}{parent_path} = $path;
            $self->_compile_resource($key, $resource->{$key});
            next;
        }

        # We'll handle endpoints specifically at the end
        next if grep {$key = $_} HTTP_METHODS;

        # TODO: Massage the rest of the data
        # TBD: This might be more appropriate to handle by going though each
        # element specifically so expansion is properly handled.
    }

    # my $res_obj = RAML::Resource->new($resource); ?
    # TBD: Easier (better?) to make a resource object?
    # TBD: If so, does the resource have compile_endpoint? Or do endpoints
    # contain their resource object?

    foreach my $method (HTTP_METHODS) {
        next unless exists($resource->{$method});

        $self->_compile_endpoint($method, $path, $resource);
    }
}

sub _compile_endpoint {
    my $self     = shift;
    my $method   = shift;
    my $path     = shift;
    my $resource = shift;

    # Generate a name
    my $name = $method . $path;
    $name =~ s{/}{_}g; # /path/to becomes _path_to
    $name =~ s/\W//g; # strip off {} around vars, etc

    # Start collecting the arguments we'll be using to create the object
    my %params = (
        name        => $name,
        path        => $path,
        description => delete($resource->{$method}{description}),
    );

    # TBD: body
    # TBD: responses
    # TBD: is
    # TBD: queryParameters
    # TBD: Others?

    my $endpoint = RAML::Endpoint->new(\%params);
    $self->endpoints->{$name} = $endpoint;
}


=head1 METHODS

=head2 function1

=cut

sub function1 {
}

=head2 function2

=cut

sub function2 {
}

=head1 AUTHOR

Sean P Quinlan, C<< <seanq at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-raml at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=RAML>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc RAML


You can also look for information at:
http://raml.org

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=RAML>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/RAML>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/RAML>

=item * Search CPAN

L<http://search.cpan.org/dist/RAML/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2016 Sean P Quinlan.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut

1; # End of RAML
