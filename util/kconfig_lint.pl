#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-2.0-only

# perltidy -l=123

package kconfig_lint;

use strict;
use warnings;
use English qw( -no_match_vars );
use File::Find;
use Getopt::Long;
use Getopt::Std;

# If taint mode is enabled, Untaint the path - git and grep must be in /bin, /usr/bin or /usr/local/bin
if ( ${^TAINT} ) {
    $ENV{'PATH'} = '/bin:/usr/bin:/usr/local/bin';
    delete @ENV{ 'IFS', 'CDPATH', 'ENV', 'BASH_ENV' };
}

my $suppress_error_output   = 0;      # flag to prevent error text
my $suppress_warning_output = 0;      # flag to prevent warning text
my $show_note_output        = 0;      # flag to show minor notes text
my $print_full_output       = 0;      # flag to print wholeconfig output
my $output_file             = "-";    # filename of output - set stdout by default
my $dont_use_git_grep       = 0;

# Globals
my $top_dir        = ".";             # Directory where Kconfig is run
my $root_dir       = "src";           # Directory of the top level Kconfig file
my $errors_found   = 0;               # count of errors
my $warnings_found = 0;
my $exclude_dirs_and_files =
  '^build/\|^util/\|^\.git/'
  . '\|^src/net\|^src/drivers/net'    # net driver contains lots of CONFIG_* macros
  . '\|^src/Makefile\.inc'            # src/Makefile.inc contains "CONFIG(option)"
  . '\|' .                            # directories to exclude when searching for used symbols
  '\.config\|\.txt$\|\.tex$\|\.tags\|/kconfig.h'; #files to exclude when looking for symbols
my $config_file = "";                 # name of config file to load symbol values from.
my @wholeconfig;                      # document the entire kconfig structure
my %loaded_files;                     # list of each Kconfig file loaded
my %symbols;                          # main structure of all symbols declared
my %referenced_symbols;               # list of symbols referenced by expressions or select statements
my %used_symbols;                     # structure of symbols used in the tree, and where they're found
my @collected_symbols;                #
my %selected_symbols;                 # list of symbols that are enabled by a select statement

my $exclude_unused = '_SPECIFIC_OPTIONS|SOUTH_BRIDGE_OPTIONS';

Main();

#-------------------------------------------------------------------------------
# Main
#
# Start by loading and parsing the top level Kconfig, this pulls in the other
# files.  Parsing the tree creates several arrays and hashes that can be used
# to check for errors
#-------------------------------------------------------------------------------
sub Main {

    check_arguments();
    open( STDOUT, "> $output_file" ) or die "Can't open $output_file for output: $!\n";

    if ( defined $top_dir ) {
        chdir $top_dir or die "Error: can't cd to $top_dir\n";
    }

    die "Error: $top_dir/$root_dir does not exist.\n" unless ( -d $root_dir );

    #load the Kconfig tree, checking what we can and building up all the hash tables
    build_and_parse_kconfig_tree("$root_dir/Kconfig");

    load_config($config_file) if ($config_file);

    check_type();
    check_defaults();
    check_referenced_symbols();

    collect_used_symbols();
    check_used_symbols();
    check_for_ifdef();
    check_for_def();
    check_config_macro();
    check_selected_symbols();

    # Run checks based on the data that was found
    if ( ( !$suppress_warning_output ) && ( ${^TAINT} == 0 ) ) {

        # The find function is tainted - only run it if taint checking
        # is disabled and warnings are enabled.
        find( \&check_if_file_referenced, $root_dir );
    }

    print_wholeconfig();

    if ($errors_found) {
        print "# $errors_found errors";
        if ($warnings_found) {
            print ", $warnings_found warnings";
        }
        print "\n";
    }

    exit( $errors_found + $warnings_found );
}

#-------------------------------------------------------------------------------
# Print and count errors
#-------------------------------------------------------------------------------
sub show_error {
    my ($error_msg) = @_;
    unless ($suppress_error_output) {
        print "#!!!!! Error: $error_msg\n";
        $errors_found++;
    }
}

#-------------------------------------------------------------------------------
# Print and count warnings
#-------------------------------------------------------------------------------
sub show_warning {
    my ($warning_msg) = @_;
    unless ($suppress_warning_output) {
        print "#!!!!! Warning: $warning_msg\n";
        $warnings_found++;
    }
}

#-------------------------------------------------------------------------------
# check selected symbols for validity
# they must be bools
# they cannot select symbols created in 'choice' blocks
#-------------------------------------------------------------------------------
sub check_selected_symbols {

    #loop through symbols found in expressions and used by 'select' keywords
    foreach my $symbol ( sort ( keys %selected_symbols ) ) {
        my $type_failure   = 0;
        my $choice_failure = 0;

        #errors selecting symbols that don't exist are already printed, so we
        #don't need to print them again here

        #make sure the selected symbols are bools
        if ( ( exists $symbols{$symbol} ) && ( $symbols{$symbol}{type} ne "bool" ) ) {
            $type_failure = 1;
        }

        #make sure we're not selecting choice symbols
        if ( ( exists $symbols{$symbol} ) && ( $symbols{$symbol}{choice} ) ) {
            $choice_failure = 1;
        }

        #loop through each instance of the symbol to print out all of the failures
        for ( my $i = 0 ; $i <= $referenced_symbols{$symbol}{count} ; $i++ ) {
            next if ( !exists $selected_symbols{$symbol}{$i} );
            my $file   = $referenced_symbols{$symbol}{$i}{filename};
            my $lineno = $referenced_symbols{$symbol}{$i}{line_no};
            if ($type_failure) {
                show_error(
                    "CONFIG_$symbol' selected at $file:$lineno." . "  Selects only work on symbols of type bool." );
            }
            if ($choice_failure) {
                show_error(
                    "'CONFIG_$symbol' selected at $file:$lineno." . "  Symbols created in a choice cannot be selected." );
            }
        }
    }
}

#-------------------------------------------------------------------------------
# check_for_ifdef - Look for instances of #ifdef CONFIG_[symbol_name] and
# #if defined(CONFIG_[symbol_name]).
#
# #ifdef symbol is valid for strings, but bool, hex, and INT are always defined.
# #if defined(symbol) && symbol is also a valid construct.
#-------------------------------------------------------------------------------
sub check_for_ifdef {
    my @ifdef_symbols = @collected_symbols;

    #look for #ifdef SYMBOL
    while ( my $line = shift @ifdef_symbols ) {
        if ( $line =~ /^([^:]+):(\d+):\s*#\s*ifn?def\s*\(?\s*CONFIG(?:_|\()(\w+)/ ) {
            my $file   = $1;
            my $lineno = $2;
            my $symbol = $3;

            if ( ( exists $symbols{$symbol} ) && ( $symbols{$symbol}{type} ne "string" ) ) {
                show_error( "#ifdef 'CONFIG_$symbol' used at $file:$lineno."
                      . "  Symbols of type '$symbols{$symbol}{type}' are always defined." );
            }
        } elsif ( $line =~ /^([^:]+):(\d+):.+defined\s*\(?\s*CONFIG(?:_|\()(\w+)/ ) {
            my $file   = $1;
            my $lineno = $2;
            my $symbol = $3;

            if ( ( exists $symbols{$symbol} ) && ( $symbols{$symbol}{type} ne "string" ) ) {
                show_error( "defined(CONFIG_$symbol) used at $file:$lineno."
                      . "  Symbols of type '$symbols{$symbol}{type}' are always defined." );
            }
        }
    }
}

#-------------------------------------------------------------------------------
# check_for_def - Look for instances of #define CONFIG_[symbol_name]
#
# Symbols should not be redefined outside of Kconfig, and #defines should not
# look like symbols
#-------------------------------------------------------------------------------
sub check_for_def {
    my @def_symbols = @collected_symbols;

    #look for #ifdef SYMBOL
    while ( my $line = shift @def_symbols ) {
        if ( $line =~ /^([^:]+):(\d+):\s*#\s*define\s+CONFIG_(\w+)/ ) {
            my $file   = $1;
            my $lineno = $2;
            my $symbol = $3;

            if ( ( exists $symbols{$symbol} ) ) {
                show_error("#define of symbol 'CONFIG_$symbol' used at $file:$lineno.");
            }
            else {
                show_error( "#define 'CONFIG_$symbol' used at $file:$lineno."
                      . "  Other #defines should not look like Kconfig symbols." );
            }
        }
    }
}

#-------------------------------------------------------------------------------
# check_type - Make sure that all symbols have a type defined.
#
# Conflicting types are found when parsing the Kconfig tree.
#-------------------------------------------------------------------------------
sub check_type {

    # loop through each defined symbol
    foreach my $sym ( sort ( keys %symbols ) ) {

        # Make sure there's a type set for the symbol
        if (!defined $symbols{$sym}{type}) {

            #loop through each instance of that symbol
            for ( my $sym_num = 0 ; $sym_num <= $symbols{$sym}{count} ; $sym_num++ ) {

                my $filename = $symbols{$sym}{$sym_num}{file};
                my $line_no  = $symbols{$sym}{$sym_num}{line_no};

                show_error("No type defined for symbol $sym defined at $filename:$line_no.");
            }
        }
    }
}

#-------------------------------------------------------------------------------
# check_config_macro - The CONFIG() macro is only valid for symbols of type
# bool. It would probably work on type hex or int if the value was 0 or 1,
# but this seems like a bad plan.  Using it on strings is dead out.
#
# The IS_ENABLED() macro is forbidden in coreboot now. Though, as long as
# we keep its definition in libpayload for compatibility, we have to check
# that it doesn't sneak back in.
#-------------------------------------------------------------------------------
sub check_config_macro {
    my @is_enabled_symbols = @collected_symbols;

    #sort through symbols found by grep and store them in a hash for easy access
    while ( my $line = shift @is_enabled_symbols ) {
        if ( $line =~ /^([^:]+):(\d+):(.+\bCONFIG\(.*)/ ) {
            my $file   = $1;
            my $lineno = $2;
            $line = $3;
            while ( $line =~ /(.*)\bCONFIG\(([^)]*)\)(.*)/ ) {
                my $symbol = $2;
                $line = $1 . $3;

                #make sure that the type is bool
                if ( exists $symbols{$symbol} ) {
                    if ( $symbols{$symbol}{type} ne "bool" ) {
                        show_error( "CONFIG($symbol) used at $file:$lineno."
                              . "  CONFIG() is only valid for type 'bool', not '$symbols{$symbol}{type}'." );
                    }
                } elsif ( $symbol =~ /^LP_/ ) {
                    # Ignore unknown libpayload configs
		} else {
                    show_error("CONFIG() used on unknown value ($symbol) at $file:$lineno.");
                }
            }
        } elsif ( $line =~ /^([^:]+):(\d+):(.+IS_ENABLED.*)/ ) {
            my $file   = $1;
            my $lineno = $2;
            $line = $3;
            if ( ( $line !~ /(.*)IS_ENABLED\s*\(\s*CONFIG_(\w+)(.*)/ ) && ( $line !~ /(\/[\*\/])(.*)IS_ENABLED/ ) ) {
                show_error("# uninterpreted IS_ENABLED at $file:$lineno: $line");
                next;
            }
            while ( $line =~ /(.*)IS_ENABLED\s*\(\s*CONFIG_(\w+)(.*)/ ) {
                my $symbol = $2;
                $line = $1 . $3;
                show_error("IS_ENABLED(CONFIG_$symbol) at $file:$lineno is deprecated. Use CONFIG($symbol) instead.");
            }
        } elsif ( $line =~ /^([^:]+):(\d+):\s*#\s*(?:el)?if\s+!?\s*\(?\s*CONFIG_(\w+)\)?(\s*==\s*1)?.*?$/ ) {
            my $file   = $1;
            my $lineno = $2;
            my $symbol = $3;
            # If the type is bool, give a warning that CONFIG() should be used
            if ( exists $symbols{$symbol} ) {
                if ( $symbols{$symbol}{type} eq "bool" ) {
                    show_error( "#if CONFIG_$symbol used at $file:$lineno."
                          . "  CONFIG($symbol) should be used for type 'bool'" );
                }
            }
        } elsif ( $line =~ /^([^:]+):(\d+):\s*#\s*(?:el)?if.*(?:&&|\|\|)\s+!?\s*\(?\s*CONFIG_(\w+)\)?(\s*==\s*1)?$/ ) {
            my $file   = $1;
            my $lineno = $2;
            my $symbol = $3;
            # If the type is bool, give a warning that CONFIG() should be used
            if ( exists $symbols{$symbol} ) {
                if ( $symbols{$symbol}{type} eq "bool" ) {
                    show_error( "#if CONFIG_$symbol used at $file:$lineno."
                          . "  CONFIG($symbol) should be used for type 'bool'" );
                }
            }
        } elsif ( $line =~ /^([^:]+):(\d+):(.+\bCONFIG_.+)/ ) {
            my $file   = $1;
            my $lineno = $2;
            $line = $3;
            if ( $file =~ /.*\.(c|h|asl|ld)/ ) {
                while ( $line =~ /(.*)\bCONFIG_(\w+)(.*)/ && $1 !~ /\/\/|\/\*/ ) {
                    my $symbol = $2;
                    $line = $1 . $3;
                    if ( exists $symbols{$symbol} ) {
                        if ( $symbols{$symbol}{type} eq "bool" ) {
                            show_error( "Naked reference to CONFIG_$symbol used at $file:$lineno."
                                . "  A 'bool' Kconfig should always be accessed through CONFIG($symbol)." );
                        }
                    } else {
                        show_warning( "Unknown config option CONFIG_$symbol used at $file:$lineno." );
                    }
                }
            }
        }
    }
}

#-------------------------------------------------------------------------------
# check_defaults - Look for defaults that come after a default with no
# dependencies.
#
# TODO - check for defaults with the same dependencies
#-------------------------------------------------------------------------------
sub check_defaults {

    # loop through each defined symbol
    foreach my $sym ( sort ( keys %symbols ) ) {
        my $default_set      = 0;
        my $default_filename = "";
        my $default_line_no  = "";

        #loop through each instance of that symbol
        for ( my $sym_num = 0 ; $sym_num <= $symbols{$sym}{count} ; $sym_num++ ) {

            #loop through any defaults for that instance of that symbol, if there are any
            next unless ( exists $symbols{$sym}{$sym_num}{default_max} );
            for ( my $def_num = 0 ; $def_num <= $symbols{$sym}{$sym_num}{default_max} ; $def_num++ ) {

                my $filename = $symbols{$sym}{$sym_num}{file};
                my $line_no  = $symbols{$sym}{$sym_num}{default}{$def_num}{default_line_no};

                # Make sure there's a type set for the symbol
                next if (!defined $symbols{$sym}{type});

                # Symbols created/used inside a choice must not have a default set. The default is set by the choice itself.
                if ($symbols{$sym}{choice}) {
                    show_error("Defining a default for symbol '$sym' at $filename:$line_no, used inside choice at "
                               . "$symbols{$sym}{choice}, is not allowed.");
                }

                # skip good defaults
                if (! ((($symbols{$sym}{type} eq "hex") && ($symbols{$sym}{$sym_num}{default}{$def_num}{default} =~ /^0x/)) ||
                    (($symbols{$sym}{type} eq "int") && ($symbols{$sym}{$sym_num}{default}{$def_num}{default} =~ /^[-0-9]+$/)) ||
                    (($symbols{$sym}{type} eq "string") && ($symbols{$sym}{$sym_num}{default}{$def_num}{default} =~ /^".*"$/)) ||
                    (($symbols{$sym}{type} eq "bool") && ($symbols{$sym}{$sym_num}{default}{$def_num}{default} =~ /^[yn]$/)))
                ) {

                    my ($checksym) = $symbols{$sym}{$sym_num}{default}{$def_num}{default} =~ /(\w+)/;

                    if (! exists $symbols{$checksym}) {

                        # verify the symbol type against the default value
                        if ($symbols{$sym}{type} eq "hex") {
                                show_error("non hex default value ($symbols{$sym}{$sym_num}{default}{$def_num}{default}) used for hex symbol $sym at $filename:$line_no.");
                        } elsif ($symbols{$sym}{type} eq "int") {
                                show_error("non int default value ($symbols{$sym}{$sym_num}{default}{$def_num}{default}) used for int symbol $sym at $filename:$line_no.");
                        } elsif  ($symbols{$sym}{type} eq "string") {
                                # TODO: Remove special MAINBOARD_DIR check
                                if ($sym ne "MAINBOARD_DIR") {
                                    show_error("no quotes around default value ($symbols{$sym}{$sym_num}{default}{$def_num}{default}) used for string symbol $sym at $filename:$line_no.");
                                }
                        } elsif  ($symbols{$sym}{type} eq "bool") {
                            if ($symbols{$sym}{$sym_num}{default}{$def_num}{default} =~ /[01YN]/) {
                                show_error("default value ($symbols{$sym}{$sym_num}{default}{$def_num}{default}) for bool symbol $sym uses value other than y/n at $filename:$line_no.");
                            } else {
                                show_error("non bool default value ($symbols{$sym}{$sym_num}{default}{$def_num}{default}) used for bool symbol $sym at $filename:$line_no.");
                            }
                        }
                    }
                }

                #if a default is already set, display an error
                if ($default_set) {
                    show_error( "Default for '$sym' referenced at $filename:$line_no will never be set"
                          . " - overridden by default set at $default_filename:$default_line_no" );
                }
                else {
                    #if no default is set, see if this is a default with no dependencies
                    unless ( ( exists $symbols{$sym}{$sym_num}{default}{$def_num}{default_depends_on} )
                        || ( exists $symbols{$sym}{$sym_num}{max_dependency} ) )
                    {
                        $default_set      = 1;
                        $default_filename = $symbols{$sym}{$sym_num}{file};
                        $default_line_no  = $symbols{$sym}{$sym_num}{default}{$def_num}{default_line_no};
                    }
                }
            }
        }
    }
}

#-------------------------------------------------------------------------------
# check_referenced_symbols - Make sure the symbols referenced by expressions and
# select statements are actually valid symbols.
#-------------------------------------------------------------------------------
sub check_referenced_symbols {

    #loop through symbols found in expressions and used by 'select' keywords
    foreach my $key ( sort ( keys %referenced_symbols ) ) {

        #make sure the symbol was defined by a 'config' or 'choice' keyword
        next if ( exists $symbols{$key} );

        #loop through each instance of the symbol to print out all of the invalid references
        for ( my $i = 0 ; $i <= $referenced_symbols{$key}{count} ; $i++ ) {
            my $filename = $referenced_symbols{$key}{$i}{filename};
            my $line_no  = $referenced_symbols{$key}{$i}{line_no};
            show_error("Undefined Symbol '$key' used at $filename:$line_no.");
        }
    }
}

#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
sub collect_used_symbols {
    # find all references to CONFIG_ statements in the tree

    if ($dont_use_git_grep) {
        @collected_symbols = `grep -Irn -- "CONFIG\\(_\\|(\\)" | grep -v '$exclude_dirs_and_files'`;
    }
    else {
        @collected_symbols = `git grep -In -- "CONFIG\\(_\\|(\\)" | grep -v '$exclude_dirs_and_files'`;
    }

    my @used_symbols = @collected_symbols;

    #sort through symbols found by grep and store them in a hash for easy access
    while ( my $line = shift @used_symbols ) {
        while ( $line =~ /[^A-Za-z0-9_]CONFIG(?:_|\()([A-Za-z0-9_]+)/g ) {
            my $symbol   = $1;
            my $filename = "";
            if ( $line =~ /^([^:]+):/ ) {
                $filename = $1;
            }

            if ( exists $used_symbols{$symbol}{count} ) {
                $used_symbols{$symbol}{count}++;
            }
            else {
                $used_symbols{$symbol}{count} = 0;
            }
            $used_symbols{$symbol}{"num_$used_symbols{$symbol}{count}"} = $filename;
        }
    }
}

#-------------------------------------------------------------------------------
# check_used_symbols - Checks to see whether or not the created symbols are
# actually used.
#-------------------------------------------------------------------------------
sub check_used_symbols {
    # loop through all defined symbols and see if they're used anywhere
    foreach my $key ( sort ( keys %symbols ) ) {

        if ( $key =~ /$exclude_unused/ ) {
            next;
        }

        #see if they're used internal to Kconfig
        next if ( exists $referenced_symbols{$key} );

        #see if they're used externally
        next if exists $used_symbols{$key};

        #loop through the definitions to print out all the places the symbol is defined.
        for ( my $i = 0 ; $i <= $symbols{$key}{count} ; $i++ ) {
            my $filename = $symbols{$key}{$i}{file};
            my $line_no  = $symbols{$key}{$i}{line_no};
            show_warning("Unused symbol '$key' referenced at $filename:$line_no.");
        }
    }
}

#-------------------------------------------------------------------------------
# build_and_parse_kconfig_tree
#-------------------------------------------------------------------------------
#load the initial file and start parsing it
sub build_and_parse_kconfig_tree {
    my ($top_level_kconfig) = @_;
    my @config_to_parse;
    my @parseline;
    my $inside_help   = 0;     # set to line number of 'help' keyword if this line is inside a help block
    my @inside_if     = ();    # stack of if dependencies
    my $inside_config = "";    # set to symbol name of the config section
    my @inside_menu   = ();    # stack of menu names
    my $inside_choice = "";
    my $choice_symbol = "";
    my $configs_inside_choice;
    my %fileinfo;

    #start the tree off by loading the top level kconfig
    @config_to_parse = load_kconfig_file( $top_level_kconfig, "", 0, 0, "", 0 );

    while ( ( @parseline = shift(@config_to_parse) ) && ( exists $parseline[0]{text} ) ) {
        my $line     = $parseline[0]{text};
        my $filename = $parseline[0]{filename};
        my $line_no  = $parseline[0]{file_line_no};

        #handle help - help text: "help" or "---help---"
        my $lastline_was_help = $inside_help;
        $inside_help = handle_help( $line, $inside_help, $inside_config, $inside_choice, $filename, $line_no );
        $parseline[0]{inside_help} = $inside_help;

        #look for basic issues in the line, strip crlf
        $line = simple_line_checks( $line, $filename, $line_no );

        #strip comments
        $line =~ s/\s*#.*$//;

        #don't parse any more if we're inside a help block
        if ($inside_help) {
            #do nothing
        }

        #handle config
        elsif ( $line =~ /^\s*config\s+/ ) {
            $line =~ /^\s*config\s+([^"\s]+)\s*(?>#.*)?$/;
            my $symbol = $1;
            $inside_config = $symbol;
            if ($inside_choice) {
                $configs_inside_choice++;
            }
            add_symbol( $symbol, \@inside_menu, $filename, $line_no, \@inside_if, $inside_choice );
        }

        #bool|hex|int|string|tristate <expr> [if <expr>]
        elsif ( $line =~ /^\s*(bool|string|hex|int|tristate)/ ) {
            $line =~ /^\s*(bool|string|hex|int|tristate)\s*(.*)/;
            my ( $type, $prompt ) = ( $1, $2 );
            handle_type( $type, $inside_config, $filename, $line_no );
            handle_prompt( $prompt, $type, \@inside_menu, $inside_config, $inside_choice, $filename, $line_no );
        }

        # def_bool|def_tristate <expr> [if <expr>]
        elsif ( $line =~ /^\s*(def_bool|def_tristate)/ ) {
            $line =~ /^\s*(def_bool|def_tristate)\s+(.*)/;
            my ( $orgtype, $default ) = ( $1, $2 );
            ( my $type = $orgtype ) =~ s/def_//;
            handle_type( $type, $inside_config, $filename, $line_no );
            handle_default( $default, $orgtype, $inside_config, $inside_choice, $filename, $line_no );
        }

        #prompt <prompt> [if <expr>]
        elsif ( $line =~ /^\s*prompt/ ) {
            $line =~ /^\s*prompt\s+(.+)/;
            handle_prompt( $1, "prompt", \@inside_menu, $inside_config, $inside_choice, $filename, $line_no );
        }

        # default <expr> [if <expr>]
        elsif ( $line =~ /^\s*default/ ) {
            $line =~ /^\s*default\s+(.*)/;
            my $default = $1;
            handle_default( $default, "default", $inside_config, $inside_choice, $filename, $line_no );
        }

        # depends on <expr>
        elsif ( $line =~ /^\s*depends\s+on/ ) {
            $line =~ /^\s*depends\s+on\s+(.*)$/;
            my $expr = $1;
            handle_depends( $expr, $inside_config, $inside_choice, $filename, $line_no );
            handle_expressions( $expr, $inside_config, $filename, $line_no );
        }

        # comment <prompt>
        elsif ( $line =~ /^\s*comment/ ) {
            $inside_config = "";
        }

        # choice [symbol]
        elsif ( $line =~ /^\s*choice/ ) {
            if ( $line =~ /^\s*choice\s*([A-Za-z0-9_]+)$/ ) {
                my $symbol = $1;
                add_symbol( $symbol, \@inside_menu, $filename, $line_no, \@inside_if );
                handle_type( "bool", $symbol, $filename, $line_no );
		$choice_symbol = $symbol;
            }
            $inside_config         = "";
            $inside_choice         = "$filename:$line_no";
            $configs_inside_choice = 0;

            # Kconfig verifies that choice blocks have a prompt
        }

        # endchoice
        elsif ( $line =~ /^\s*endchoice/ ) {
            $inside_config = "";
            if ( !$inside_choice ) {
                show_error("'endchoice' keyword not within a choice block at $filename:$line_no.");
            }

            $inside_choice = "";
            if (( $configs_inside_choice == 0 ) &&
	        ( $choice_symbol eq "" )) {
                show_error("unnamed choice block has no symbols at $filename:$line_no.");
            }
            $configs_inside_choice = 0;
	    $choice_symbol="";
        }

        # [optional]
        elsif ( $line =~ /^\s*optional/ ) {
            if ($inside_config) {
                show_error( "Keyword 'optional' appears inside config for '$inside_config'"
                      . " at $filename:$line_no.  This is not valid." );
            }
            if ( !$inside_choice ) {
                show_error( "Keyword 'optional' appears outside of a choice block"
                      . " at $filename:$line_no.  This is not valid." );
            }
        }

        # mainmenu <prompt>
        elsif ( $line =~ /^\s*mainmenu/ ) {
            $inside_config = "";

            # Kconfig alread checks for multiple 'mainmenu' entries and mainmenu entries with no prompt
            # Possible check: look for 'mainmenu ""'
            # Possible check: verify that a mainmenu has been specified
        }

        # menu <prompt>
        elsif ( $line =~ /^\s*menu/ ) {
            $line =~ /^\s*menu\s+(.*)/;
            my $menu = $1;
            if ( $menu =~ /^\s*"([^"]*)"\s*$/ ) {
                $menu = $1;
            }

            $inside_config = "";
            $inside_choice = "";
            push( @inside_menu, $menu );
        }

        # visible if <expr>
        elsif ( $line =~ /^\s*visible if.*$/ ) {
        # Must come directly after menu line (and on a separate line)
        # but kconfig already checks for that.
        # Ignore it.
        }

        # endmenu
        elsif ( $line =~ /^\s*endmenu/ ) {
            $inside_config = "";
            $inside_choice = "";
            pop @inside_menu;
        }

        # "if" <expr>
        elsif ( $line =~ /^\s*if/ ) {
            $inside_config = "";
            $line =~ /^\s*if\s+(.*)$/;
            my $expr = $1;
            push( @inside_if, $expr );
            handle_expressions( $expr, $inside_config, $filename, $line_no );
            $fileinfo{$filename}{iflevel}++;
        }

        # endif
        elsif ( $line =~ /^\s*endif/ ) {
            $inside_config = "";
            pop(@inside_if);
            $fileinfo{$filename}{iflevel}--;
        }

        #range <symbol> <symbol> [if <expr>]
        elsif ( $line =~ /^\s*range/ ) {
            $line =~ /^\s*range\s+(\S+)\s+(.*)$/;
            handle_range( $1, $2, $inside_config, $filename, $line_no );
        }

        # select <symbol> [if <expr>]
        elsif ( $line =~ /^\s*select/ ) {
            unless ($inside_config) {
                show_error("Keyword 'select' appears outside of config at $filename:$line_no.  This is not valid.");
            }

            if ( $line =~ /^\s*select\s+(.*)$/ ) {
                $line = $1;
                my $expression;
                ( $line, $expression ) = handle_if_line( $line, $inside_config, $filename, $line_no );
                if ($line) {
                    add_referenced_symbol( $line, $filename, $line_no, 'select' );
                }
            }
        }

        # source <prompt>
        elsif ( $line =~ /^\s*source\s+"?([^"\s]+)"?\s*(?>#.*)?$/ ) {
            my @newfile = load_kconfig_file( $1, $filename, $line_no, 0, $filename, $line_no );
            unshift( @config_to_parse, @newfile );
            $parseline[0]{text} = "# '$line'\n";
        }
        elsif (
            ( $line =~ /^\s*#/ ) ||    #comments
            ( $line =~ /^\s*$/ )       #blank lines
          )
        {
            # do nothing
        }
        else {
            if ($lastline_was_help) {
                show_error("The line \"$line\"  ($filename:$line_no) wasn't recognized - supposed to be inside help?");
            }
            else {
                show_error("The line \"$line\"  ($filename:$line_no) wasn't recognized");
            }
        }

        if ( defined $inside_menu[0] ) {
            $parseline[0]{menus} = "";
        }
        else {
            $parseline[0]{menus} = "top";
        }

        my $i = 0;
        while ( defined $inside_menu[$i] ) {
            $parseline[0]{menus} .= "$inside_menu[$i]";
            $i++;
            if ( defined $inside_menu[$i] ) {
                $parseline[0]{menus} .= "->";
            }
        }
        push @wholeconfig, @parseline;
    }

    foreach my $file ( keys %fileinfo ) {
        if ( $fileinfo{$file}{iflevel} > 0 ) {
            show_error("$file has $fileinfo{$file}{iflevel} more 'if' statement(s) than 'endif' statements.");
        }
        elsif ( $fileinfo{$file}{iflevel} < 0 ) {
            show_error(
                "$file has " . ( $fileinfo{$file}{iflevel} * -1 ) . " more 'endif' statement(s) than 'if' statements." );
        }
    }
}

#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
sub handle_depends {
    my ( $expr, $inside_config, $inside_choice, $filename, $line_no ) = @_;

    if ($inside_config) {
        my $sym_num = $symbols{$inside_config}{count};
        if ( exists $symbols{$inside_config}{$sym_num}{max_dependency} ) {
            $symbols{$inside_config}{$sym_num}{max_dependency}++;
        }
        else {
            $symbols{$inside_config}{$sym_num}{max_dependency} = 0;
        }

        my $dep_num = $symbols{$inside_config}{$sym_num}{max_dependency};
        $symbols{$inside_config}{$sym_num}{dependency}{$dep_num} = $expr;
    }
}

#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
sub add_symbol {
    my ( $symbol, $menu_array_ref, $filename, $line_no, $ifref, $inside_choice ) = @_;
    my @inside_if = @{$ifref};

    #initialize the symbol or increment the use count.
    if ( ( !exists $symbols{$symbol} ) || ( !exists $symbols{$symbol}{count} ) ) {
        $symbols{$symbol}{count} = 0;
        # remember the location of the choice (or "")
        $symbols{$symbol}{choice} = $inside_choice;
    }
    else {
        $symbols{$symbol}{count}++;
        if ( $inside_choice && $symbols{$symbol}{choice} ) {
            show_error( "$symbol entry at $filename:$line_no has already been created inside another choice block "
                  . "at $symbols{$symbol}{0}{file}:$symbols{$symbol}{0}{line_no}." );
        }
    }

    # add the location of this instance
    my $symcount = $symbols{$symbol}{count};
    $symbols{$symbol}{$symcount}{file}    = $filename;
    $symbols{$symbol}{$symcount}{line_no} = $line_no;

    #Add the menu structure
    if ( defined @$menu_array_ref[0] ) {
        $symbols{$symbol}{$symcount}{menu} = $menu_array_ref;
    }

    #Add any 'if' statements that the symbol is inside as dependencies
    if (@inside_if) {
        my $dep_num = 0;
        for my $dependency (@inside_if) {
            $symbols{$symbol}{$symcount}{dependency}{$dep_num} = $dependency;
            $symbols{$symbol}{$symcount}{max_dependency} = $dep_num;
            $dep_num++;
        }
    }
}

#-------------------------------------------------------------------------------
# handle range
#-------------------------------------------------------------------------------
sub handle_range {
    my ( $range1, $range2, $inside_config, $filename, $line_no ) = @_;

    my $expression;
    ( $range2, $expression ) = handle_if_line( $range2, $inside_config, $filename, $line_no );

    $range1 =~ /^\s*(?:0x)?([A-Fa-f0-9]+)\s*$/;
    my $checkrange1 = $1;
    $range2 =~ /^\s*(?:0x)?([A-Fa-f0-9]+)\s*$/;
    my $checkrange2 = $1;

    if ( $checkrange1 && $checkrange2 && ( hex($checkrange1) > hex($checkrange2) ) ) {
        show_error("Range entry in $filename line $line_no value 1 ($range1) is greater than value 2 ($range2).");
    }

    if ($inside_config) {
        if ( exists( $symbols{$inside_config}{range1} ) ) {
            if ( ( $symbols{$inside_config}{range1} != $range1 ) || ( $symbols{$inside_config}{range2} != $range2 ) ) {
                if ($show_note_output) {
                    print "#!!!!! Note: Config '$inside_config' range entry $range1 $range2 at $filename:$line_no does";
                    print " not match the previously defined range $symbols{$inside_config}{range1}"
                      . " $symbols{$inside_config}{range2}";
                    print " defined at $symbols{$inside_config}{range_file}:$symbols{$inside_config}{range_line_no}.\n";
                }
            }
        }
        else {
            $symbols{$inside_config}{range1}        = $range1;
            $symbols{$inside_config}{range2}        = $range2;
            $symbols{$inside_config}{range_file}    = $filename;
            $symbols{$inside_config}{range_line_no} = $line_no;
        }
    }
    else {
        show_error("Range entry at $filename:$line_no is not inside a config block.");
    }
}

#-------------------------------------------------------------------------------
# handle_default
#-------------------------------------------------------------------------------
sub handle_default {
    my ( $default, $name, $inside_config, $inside_choice, $filename, $line_no ) = @_;
    my $expression;
    ( $default, $expression ) = handle_if_line( $default, $inside_config, $filename, $line_no );

    if ($inside_config) {
        handle_expressions( $default, $inside_config, $filename, $line_no );
        my $sym_num = $symbols{$inside_config}{count};

        unless ( exists $symbols{$inside_config}{$sym_num}{default_max} ) {
            $symbols{$inside_config}{$sym_num}{default_max} = 0;
        }
        my $default_max = $symbols{$inside_config}{$sym_num}{default_max};
        $symbols{$inside_config}{$sym_num}{default}{$default_max}{default}         = $default;
        $symbols{$inside_config}{$sym_num}{default}{$default_max}{default_line_no} = $line_no;
        if ($expression) {
            $symbols{$inside_config}{$sym_num}{default}{$default_max}{default_depends_on} = $expression;
        }
    }
    elsif ($inside_choice) {
        handle_expressions( $default, $inside_config, $filename, $line_no );
    }
    else {
        show_error("$name entry at $filename:$line_no is not inside a config or choice block.");
    }
}

#-------------------------------------------------------------------------------
# handle_if_line
#-------------------------------------------------------------------------------
sub handle_if_line {
    my ( $exprline, $inside_config, $filename, $line_no ) = @_;

    if ( $exprline !~ /if/ ) {
        return ( $exprline, "" );
    }

    #remove any quotes that might have an 'if' in them
    my $savequote;
    if ( $exprline =~ /^\s*("[^"]+")/ ) {
        $savequote = $1;
        $exprline =~ s/^\s*("[^"]+")//;
    }

    my $expr = "";
    if ( $exprline =~ /\s*if\s+(.*)$/ ) {
        $expr = $1;
        $exprline =~ s/\s*if\s+.*$//;

        if ($expr) {
            handle_expressions( $expr, $inside_config, $filename, $line_no );
        }
    }

    if ($savequote) {
        $exprline = $savequote;
    }

    return ( $exprline, $expr );
}

#-------------------------------------------------------------------------------
# handle_symbol - log which symbols are being used
#-------------------------------------------------------------------------------
sub handle_symbol {
    my ( $symbol, $filename, $line_no ) = @_;

    #filter constant symbols first
    if ( $symbol =~ /^[yn]$/ ) {                    # constant y/n
        return;
    }
    if ( $symbol =~ /^-?(?:0x)?\p{XDigit}+$/ ) {    # int/hex values
        return;
    }
    if ( $symbol =~ /^"[^"]*"$/ ) {                 # string values
        return;
    }

    if ( $symbol =~ /^([A-Za-z0-9_]+)$/ ) {         # actual symbol
        add_referenced_symbol( $1, $filename, $line_no, 'expression' );
    }
    else {
        show_error("Unrecognized expression: expected symbol, "
                    . "found '$symbol' in $filename line $line_no.");
    }
}

#-------------------------------------------------------------------------------
# handle_expressions - find symbols in expressions
#-------------------------------------------------------------------------------
sub handle_expressions {
    my ( $exprline, $inside_config, $filename, $line_no ) = @_;

    my $strip = qr/\s*(.*[^\s]+)\s*/;

    my $parens = qr/(\((?:[^\(\)]++|(?-1))*\))/;
    my $quotes = qr/"[^"]*"/;
    my $balanced = qr/((?:$parens|$quotes|[^\(\)"])+)/;

    if ( $exprline =~ /^\s*$balanced\s*(?:\|\||&&)\s*(.+)$/ ) {
        # <expr> '||' <expr>, <expr> '&&' <expr>                  (8)(7)
        my ( $lhs, $rhs ) = ( $1, $3 );
        handle_expressions( $lhs, $inside_config, $filename, $line_no );
        handle_expressions( $rhs, $inside_config, $filename, $line_no );
    }
    elsif ( $exprline =~ /^\s*!(.+)$/ ) {
        # '!' <expr>                                                 (6)
        handle_expressions( $1, $inside_config, $filename, $line_no );
    }
    elsif ( $exprline =~ /^\s*$parens\s*$/ ) {
        # '(' <expr> ')'                                             (5)
        $exprline =~ /^\s*\((.*)\)\s*$/;
        handle_expressions( $1, $inside_config, $filename, $line_no );
    }
    elsif ( $exprline =~ /^\s*($quotes|[^"\s]+)\s*(?:[<>]=?|!=)$strip$/ ) {
        # <symbol> '<' <symbol>, <symbol> '!=' <symbol>, etc.     (4)(3)
        my ( $lhs, $rhs ) = ( $1, $2 );
        handle_symbol( $lhs, $filename, $line_no );
        handle_symbol( $rhs, $filename, $line_no );
    }
    elsif ( $exprline =~ /^\s*($quotes|[^"\s]+)\s*=$strip$/ ) {
        # <symbol> '=' <symbol>                                      (2)
        my ( $lhs, $rhs ) = ( $1, $2 );
        handle_symbol( $lhs, $filename, $line_no );
        handle_symbol( $rhs, $filename, $line_no );
    }
    elsif ( $exprline =~ /^$strip$/ ) {
        # <symbol>                                                   (1)
        handle_symbol( $1, $filename, $line_no );
    }
}

#-------------------------------------------------------------------------------
# add_referenced_symbol
#-------------------------------------------------------------------------------
sub add_referenced_symbol {
    my ( $symbol, $filename, $line_no, $reftype ) = @_;
    if ( exists $referenced_symbols{$symbol} ) {
        $referenced_symbols{$symbol}{count}++;
        $referenced_symbols{$symbol}{ $referenced_symbols{$symbol}{count} }{filename} = $filename;
        $referenced_symbols{$symbol}{ $referenced_symbols{$symbol}{count} }{line_no}  = $line_no;
    }
    else {
        $referenced_symbols{$symbol}{count}       = 0;
        $referenced_symbols{$symbol}{0}{filename} = $filename;
        $referenced_symbols{$symbol}{0}{line_no}  = $line_no;
    }

    #mark the symbol as being selected, use referenced symbols for location
    if ( $reftype eq 'select' ) {
        $selected_symbols{$symbol}{ $referenced_symbols{$symbol}{count} } = 1;
    }
}

#-------------------------------------------------------------------------------
# handle_help
#-------------------------------------------------------------------------------
{
    #create a non-global static variable by enclosing it and the subroutine
    my $help_whitespace = "";    #string to show length of the help whitespace
    my $help_keyword_whitespace = "";

    sub handle_help {
        my ( $line, $inside_help, $inside_config, $inside_choice, $filename, $line_no ) = @_;

        if ($inside_help) {

            #get the indentation level if it's not already set.
            if ( ( !$help_whitespace ) && ( $line !~ /^[\r\n]+/ ) ) {
                $line =~ /^(\s+)/;    #find the indentation level.
                $help_whitespace = $1;
                if ( !$help_whitespace ) {
                    show_error("$filename:$line_no - help text starts with no whitespace.");
                    return $inside_help;
                }
                elsif ($help_keyword_whitespace eq $help_whitespace) {
                    show_error("$filename:$line_no - help text needs additional indentation.");
                    return $inside_help;
                }
            }

            #help ends at the first line which has a smaller indentation than the first line of the help text.
            if ( ( $line !~ /^$help_whitespace/ ) && ( $line !~ /^[\r\n]+/ ) ) {
                $inside_help     = 0;
                $help_whitespace = "";
                $help_keyword_whitespace = "";
            }
            else {    #if it's not ended, add the line to the helptext array for the symbol's instance
                if ($inside_config) {
                    my $sym_num = $symbols{$inside_config}{count};
                    if ($help_whitespace) { $line =~ s/^$help_whitespace//; }
                    push( @{ $symbols{$inside_config}{$sym_num}{helptext} }, $line );
                }
                if ( ($help_keyword_whitespace eq $help_whitespace) && ( $line !~ /^[\r\n]+/ ) ) {
                    show_error("$filename:$line_no - help text needs additional indentation.");
                }
            }
        }
        elsif ( ( $line =~ /^(\s*)help/ ) || ( $line =~ /^(\s*)---help---/ ) ) {
            $inside_help = $line_no;
            $line =~ /^(\s+)/;
            $help_keyword_whitespace = $1;
            if ( ( !$inside_config ) && ( !$inside_choice ) ) {
                if ($show_note_output) {
                    print "# Note: $filename:$line_no help is not inside a config or choice block.\n";
                }
            }
            elsif ($inside_config) {
                $help_whitespace = "";
                my $sym_num = $symbols{$inside_config}{count};
                $symbols{$inside_config}{$sym_num}{help_line_no} = $line_no;
                $symbols{$inside_config}{$sym_num}{helptext}     = ();
            }
        }
        return $inside_help;
    }
}

#-------------------------------------------------------------------------------
# handle_type
#-------------------------------------------------------------------------------
sub handle_type {
    my ( $type, $inside_config, $filename, $line_no ) = @_;

    my $expression;
    ( $type, $expression ) = handle_if_line( $type, $inside_config, $filename, $line_no );

    if ( $type =~ /tristate/ ) {
        show_error("$filename:$line_no - tristate types are not used.");
    }

    if ($inside_config) {
        if ( exists( $symbols{$inside_config}{type} ) ) {
            if ( $symbols{$inside_config}{type} !~ /$type/ ) {
                show_error( "Config '$inside_config' type entry $type"
                      . " at $filename:$line_no does not match $symbols{$inside_config}{type}"
                      . " defined at $symbols{$inside_config}{type_file}:$symbols{$inside_config}{type_line_no}." );
            }
        }
        else {
            $symbols{$inside_config}{type}         = $type;
            $symbols{$inside_config}{type_file}    = $filename;
            $symbols{$inside_config}{type_line_no} = $line_no;
        }
    }
    else {
        show_error("Type entry at $filename:$line_no is not inside a config block.");
    }
}

#-------------------------------------------------------------------------------
# handle_prompt
#-------------------------------------------------------------------------------
sub handle_prompt {
    my ( $prompt, $name, $menu_array_ref, $inside_config, $inside_choice, $filename, $line_no ) = @_;

    my $expression;
    ( $prompt, $expression ) = handle_if_line( $prompt, $inside_config, $filename, $line_no );

    if ($inside_config) {
        if ( $prompt !~ /^\s*$/ ) {
            if ( $prompt =~ /^\s*"([^"]*)"\s*$/ ) {
                $prompt = $1;
            }

            #display an error if there's a prompt at the top menu level
            if ( !defined @$menu_array_ref[0] ) {
                show_error( "Symbol  '$inside_config' with prompt '$prompt' appears outside of a menu"
                      . " at $filename:$line_no." );
            }

            my $sym_num = $symbols{$inside_config}{count};
            if ( !exists $symbols{$inside_config}{$sym_num}{prompt_max} ) {
                $symbols{$inside_config}{$sym_num}{prompt_max} = 0;
            }
            else {
                $symbols{$inside_config}{$sym_num}{prompt_max}++;
            }
            my $prompt_max = $symbols{$inside_config}{$sym_num}{prompt_max};
            $symbols{$inside_config}{$sym_num}{prompt}{$prompt_max}{prompt}         = $prompt;
            $symbols{$inside_config}{$sym_num}{prompt}{$prompt_max}{prompt_line_no} = $line_no;

            $symbols{$inside_config}{$sym_num}{prompt}{$prompt_max}{prompt_menu} = @$menu_array_ref;
            if ($expression) {
                $symbols{$inside_config}{$sym_num}{prompt}{$prompt_max}{prompt_depends_on} = $expression;
            }
        }
    }
    elsif ($inside_choice) {

        #do nothing
    }
    else {
        show_error("$name entry at $filename:$line_no is not inside a config or choice block.");
    }
}

#-------------------------------------------------------------------------------
# simple_line_checks - Does some basic checks on the current line, then cleans the line
#  up for further processing.
#-------------------------------------------------------------------------------
sub simple_line_checks {
    my ( $line, $filename, $line_no ) = @_;

    #check for spaces instead of tabs
    if ( $line =~ /^ +/ ) {
        show_error("$filename:$line_no starts with a space.");
    }

    #verify a linefeed at the end of the line
    if ( $line !~ /.*\n/ ) {
        show_error( "$filename:$line_no does not end with linefeed."
              . "  This can cause the line to not be recognized by the Kconfig parser.\n#($line)" );
        $line =~ s/\s*$//;
    }
    else {
        chop($line);
    }

    return $line;
}

#-------------------------------------------------------------------------------
# load_kconfig_file - Loads a single Kconfig file or expands * wildcard
#-------------------------------------------------------------------------------
sub load_kconfig_file {
    my ( $input_file, $loadfile, $loadline, $expanded, $topfile, $topline ) = @_;
    my @file_data;
    my @dir_file_data;

    #recursively handle coreboot's new source glob operator
    if ( $input_file =~ /^(.*?)\/(\w*)\*(\w*)\/(.*)$/ ) {
        my $dir_prefix = $1;
        my $dir_glob_prefix = $2;
        my $dir_glob_suffix = $3;
        my $dir_suffix = $4;
        if ( -d "$dir_prefix" ) {

            opendir( D, "$dir_prefix" ) || die "Can't open directory '$dir_prefix'\n";
            my @dirlist = sort { $a cmp $b } readdir(D);
            closedir(D);

            while ( my $directory = shift @dirlist ) {

                #ignore non-directory files
                if ( ( -d "$dir_prefix/$directory" ) && !( $directory =~ /^\..*/ )
                     && ( $directory =~ /\Q$dir_glob_prefix\E.*\Q$dir_glob_suffix\E/ ) ) {
                    push @dir_file_data,
                      load_kconfig_file( "$dir_prefix/$directory/$dir_suffix",
                        $input_file, $loadline, 1, $loadfile, $loadline );
                }
            }
        }

        #the directory should exist when using a glob
        else {
            show_error("Could not find dir '$dir_prefix'");
        }
    }

    #if the file exists, try to load it.
    elsif ( -e "$input_file" ) {

        #throw a warning if the file has already been loaded.
        if ( exists $loaded_files{$input_file} ) {
            show_warning("'$input_file' sourced at $loadfile:$loadline was already loaded by $loaded_files{$input_file}");
        }

        #load the file's contents and mark the file as loaded for checking later
        open( my $HANDLE, "<", "$input_file" ) or die "Error: could not open file '$input_file'\n";
        @file_data = <$HANDLE>;
        close $HANDLE;
        $loaded_files{$input_file} = "'$loadfile' line $loadline";
    }

    # if the file isn't being loaded from a glob, it should exist.
    elsif ( $expanded == 0 ) {
        show_warning("Could not find file '$input_file' sourced at $loadfile:$loadline");
    }

    my $line_in_file = 0;
    while ( my $line = shift @file_data ) {

        #handle line continuation.
        my $continue_line = 0;
        while ( $line =~ /(.*)\s+\\$/ ) {
            my $text = $1;

            # get rid of leading whitespace on all but the first and last lines
            $text =~ s/^\s*/ / if ($continue_line);

            $dir_file_data[$line_in_file]{text} .= $text;
            $line = shift @file_data;
            $continue_line++;

            #put the data into the continued lines (other than the first)
            $line =~ /^\s*(.*)\s*$/;

            $dir_file_data[ $line_in_file + $continue_line ]{text}         = "\t# continued line ( " . $1 . " )\n";
            $dir_file_data[ $line_in_file + $continue_line ]{filename}     = $input_file;
            $dir_file_data[ $line_in_file + $continue_line ]{file_line_no} = $line_in_file + $continue_line + 1;

            #get rid of multiple leading spaces for last line
            $line = " $1\n";
        }

        $dir_file_data[$line_in_file]{text} .= $line;
        $dir_file_data[$line_in_file]{filename}     = $input_file;
        $dir_file_data[$line_in_file]{file_line_no} = $line_in_file + 1;

        $line_in_file++;
        if ($continue_line) {
            $line_in_file += $continue_line;
        }
    }

    if ($topfile) {
        my %file_data;
        $file_data{text}         = "\t### File '$input_file' loaded from '$topfile' line $topline\n";
        $file_data{filename}     = $topfile;
        $file_data{file_line_no} = "($topline)";
        unshift( @dir_file_data, \%file_data );
    }

    return @dir_file_data;
}

#-------------------------------------------------------------------------------
# print_wholeconfig - prints out the parsed Kconfig file
#-------------------------------------------------------------------------------
sub print_wholeconfig {

    return unless $print_full_output;

    for ( my $i = 0 ; $i <= $#wholeconfig ; $i++ ) {
        my $line = $wholeconfig[$i];
        chop( $line->{text} );

        #replace tabs with spaces for consistency
        $line->{text} =~ s/\t/        /g;
        printf "%-120s # $line->{filename} line $line->{file_line_no} ($line->{menus})\n", $line->{text};
    }
}

#-------------------------------------------------------------------------------
# check_if_file_referenced - checks for kconfig files that are not being parsed
#-------------------------------------------------------------------------------
sub check_if_file_referenced {
    my $filename = $File::Find::name;
    if (   ( $filename =~ /Kconfig/ )
        && ( !$filename =~ /\.orig$/ )
        && ( !$filename =~ /~$/ )
        && ( !exists $loaded_files{$filename} ) )
    {
        show_warning("'$filename' is never referenced");
    }
}

#-------------------------------------------------------------------------------
# check_arguments parse the command line arguments
#-------------------------------------------------------------------------------
sub check_arguments {
    my $show_usage = 0;
    GetOptions(
        'help|?'         => sub { usage() },
        'e|errors_off'   => \$suppress_error_output,
        'n|notes'        => \$show_note_output,
        'o|output=s'     => \$output_file,
        'p|print'        => \$print_full_output,
        'w|warnings_off' => \$suppress_warning_output,
        'path=s'         => \$top_dir,
        'c|config=s'     => \$config_file,
        'G|no_git_grep'  => \$dont_use_git_grep,
    );

    if ($suppress_error_output) {
        $suppress_warning_output = 1;
    }
    if ($suppress_warning_output) {
        $show_note_output = 0;
    }
}

#-------------------------------------------------------------------------------
# usage - Print the arguments for the user
#-------------------------------------------------------------------------------
sub usage {
    print "kconfig_lint <options>\n";
    print " -o|--output=file    Set output filename\n";
    print " -p|--print          Print full output\n";
    print " -e|--errors_off     Don't print warnings or errors\n";
    print " -w|--warnings_off   Don't print warnings\n";
    print " -n|--notes          Show minor notes\n";
    print " --path=dir          Path to top level kconfig\n";
    print " -c|--config=file    Filename of config file to load\n";
    print " -G|--no_git_grep    Use standard grep tools instead of git grep\n";

    exit(0);
}

1;
