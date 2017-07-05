#!/bin/sh
# the next line restarts using tclsh \
exec tclsh "$0" "$@"

set resolvedArgv0 [file dirname [file normalize $argv0/___]];  # Trick to resolve last symlink
set appname [file rootname [file tail $resolvedArgv0]]
set rootdir [file normalize [file dirname $resolvedArgv0]]
foreach module [list toclbox] {
    foreach search [list lib/$module ../common/$module] {
        set dir [file join $rootdir $search]
        if { [file isdirectory $dir] } {
            ::tcl::tm::path add $dir
        }
    }
}
foreach search [list lib/modules] {
    set dir [file join $rootdir $search]
    if { [file isdirectory $dir] } {
	::tcl::tm::path add $dir
    }
}
foreach module [list til] {
    foreach search [list lib/$module ../common/$module] {
        set dir [file join $rootdir $search]
        if { [file isdirectory $dir] } {
            lappend auto_path $dir
        }
    }
}
package require Tcl 8.6
package require toclbox
package require mqtt
package require http
package require minihttpd
set prg_args {
    -help       ""          "Print this help and exit"
    -verbose    "* DEBUG"   "Verbosity specification for program and modules"
    -port       1883        "Port to send to"
    -host       localhost   "Hostname of remote server"
    -user       ""          "Username to authenticate with"
    -password   ""          "Password to authenticate with"
    -keepalive  60          "MQTT keepalive to server (in seconds)"
    -retransmit 5000        "Topic retransmission, in ms."
    -omit       ""          "Remove this leading string from destination topic"
    -prepend    ""          "Add this before topic"
    -append    ""           "Add this after topic"
    -qos        1           "QoS level"
    -retain     0           "Retain at MQTT server"
    -http       "http:8080" "List of protocols and ports for HTTP servicing"
    -authorization ""       "HTTPd authorizations (pattern realm authlist)"
    -exts       "%prgdir%/exts" "Path to plugins directory"
    -routes     "* - \"\""  "Topic routing: default is direct mapping of ALL reqs!"
}


# ::help:dump -- Dump help
#
#       Dump help based on the command-line option specification and
#       exit.
#
# Arguments:
#	hdr	Leading text to prepend to help message
#
# Results:
#       None.
#
# Side Effects:
#       Exit program
proc ::help:dump { { hdr "" } } {
    global appname
    
    if { $hdr ne "" } {
	puts $hdr
	puts ""
    }
    puts "NAME:"
    puts "\t$appname - Forwards POSTed data to MQTT topics"
    puts ""
    puts "USAGE"
    puts "\t${appname}.tcl \[options\] -- \[controlled program\]"
    puts ""
    puts "OPTIONS:"
    foreach { arg val dsc } $::prg_args {
	puts "\t[string range ${arg}[string repeat \  10] 0 10]$dsc (default: ${val})"
    }
    exit    
}
# Did we ask for help at the command-line, print out all command-line
# options described above and exit.
toclbox pullopt argv opts
if { [toclbox getopt opts -help] } {
    ::help:dump
}

# Extract list of command-line options into array that will contain
# program state.  The description array contains help messages, we get
# rid of them on the way into the main program's status array.
array set H2M {
    plugins {}
}
foreach { arg val dsc } $prg_args {
    set H2M($arg) $val
}
for { set eaten "" } {$eaten ne $opts } {} {
    set eaten $opts
    foreach opt [array names H2M -*] {
        toclbox pushopt opts $opt H2M
    }
}
# Remaining args? Dump help and exit
if { [llength $opts] > 0 } {
    ::help:dump "[lindex $opts 0] is an unknown command-line option!"
}
# Setup program verbosity and arrange to print out how we were started if
# relevant.
toclbox verbosity {*}$H2M(-verbose)
set startup "Starting $appname with following options\n"
foreach {k v} [array get H2M -*] {
    append startup "\t[string range $k[string repeat \  10] 0 10]: $v\n"
}
toclbox debug DEBUG [string trim $startup]

# Possibly read authorization and routes information from files instead, since
# these might get big
toclbox offload H2M(-authorization) 3 "authorizations"
toclbox offload H2M(-routes) 3 "routes"


# ::send -- send data to topic
#
#       Send data to topic at remote MQTT server. This procedure, apart from the
#       topic and the data to be sent to the remote MQTT server, takes a number
#       of dash-led options and their values. The recognised options are -qos
#       and -retain and these will override the defaults that are coming from
#       the options passed to the main program.
#
# Arguments:
#	topic	Topic where to send
#	data	Content of MQTT message
#       args    Additional dash-led options and values
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::send { topic data args } {
    global H2M
    
    toclbox getopt args qos -default $H2M(-qos) -value qos
    toclbox getopt args retain -default $H2M(-retain) -value retain
    toclbox getopt args override -default 0 -value override
    
    if { ! $override } {
        # Modify destination topic according to program options, this allows to
        # perform some simple re-routing of topics within the topic space, for
        # example to pick various MQTT servers behind a load-balancer or
        # similar. 
        if { $H2M(-omit) ne "" && [string first $H2M(-omit) $topic] == 0 } {
            set topic [string range $topic [string length $H2M(-omit)] end]
        }
        set topic $H2M(-prepend)${topic}$H2M(-append)
    }
    
    toclbox log debug "Passing data to MQTT server, topic: $topic (QoS: $qos, Retain: $retain)"
    $H2M(client) publish $topic $data $qos $retain    
}

# ::forward -- HTTP router
#
#       This procedure is called back whenever one of the HTTP path
#       matching the routes specified as part of the -routes option
#       matches.  The route should either be an empty string or the
#       dash, in which case the data posted is forwarded to the same
#       STOMP topic as the path of the HTTP request.  Otherwise, the
#       route should be the name of a procedure followed by the @-sign
#       followed by the path to a plugin.  The procedure will be
#       called with the identifier of the STOMP connection, the path
#       of the HTTP request and the posted data.  It will be able to
#       send STOMP data using a command called stomp, to the topic
#       that it decides.
#
# Arguments:
#	route	Destination for data (see above).
#	prt	Port of the HTTP server at which request was received
#	sock	Socket to client at the time of the request
#	url	Path requested
#	qry	HTTP query data
#
# Results:
#       None.
#
# Side Effects:
#       Forwards data to MQTT topics, either directly or through
#       plugins.
proc ::forward { route prt sock url qry } {
    global H2M

    # Get to data for the query (i.e. what was sent through the POST).
    # We won't do anything if no data is present once we've trimmed
    # it.
    set data [string trim [::minihttpd::data $prt $sock]]
    if { $data eq "" } {
	set data $qry
    }

    if { $data ne "" } {
	toclbox log debug "Incoming data on $prt with path $url"
	# If we don't have a route specified, then we simply believe
	# that the path of the HTTP request is the same than the MQTT
	# topic and we forward all data on that topic.
	if { $route eq "" || $route eq "-" } {
            ::send $url $data
	} else {
	    # Otherwise, we call the specified procedure within the
	    # safe interpreter (as long as it exists, but it should
	    # have been created as part of the initialisation
	    # process).  The procedure should arrange itself to call
	    # the command called stomp, which really is an alias for
	    # ::stomp::client::send.
	    foreach {proc fname} [split $route "@"] break
	    if { [dict exists $H2M(plugins) $fname] \
		     && [interp exists $fname] } {
		# Isolate procedure name from possible arguments.
		set call [split $proc !]
		set proc [lindex $call 0]
		set args [lrange $call 1 end]
		# Pass STOMP client identifier, requested URL and
		# POSTed data to the plugin procedure.
		if { [catch {$fname eval [linsert $args 0 $proc $url $data]} res] } {
		    toclbox log warn "Error when calling back $proc: $res"
		} else {
		    toclbox log debug "Successfully called $proc for $url: $res"
                    return $res;    # Matched, return result
		}
	    } else {
                toclbox log warn "Cannot find plugin at $fname for $url"
            }
	}
    }
    return ""
}


# ::http:init -- Initialise HTTP listening on port
#
#       Start serving HTTP requests on the port passed as an argument.
#       We arrange for not servicing any file and for the internal
#       procedure forwarder to be called for the routes specified as
#       part of the -routes options.  forwarder will be in charge of
#       forwarding data to MQTT topics, possibly through the
#       specified plugins.
#
# Arguments:
#	port	HTTP port to listen on.
#
# Results:
#       Return the identifier of the server (an integer), negative on
#       errors.
#
# Side Effects:
#       None.
proc ::http:init { port } {
    global H2M

    toclbox log notice "Starting to serve HTTP request on port $port"
    set srv [::minihttpd::new "" $port -authorization $H2M(-authorization)]
    if { $srv < 0 } {
	return -1
    }

    foreach { path route } $H2M(-routes) {
	::minihttpd::handler $srv $path [list ::forward $route] "text/plain"
    }

    return $srv
}


# ::htinit -- Initialise all HTTP servers.
#
#       Loops through the -http option to start serving for HTTP (or
#       HTTPS later?) requests on the pinpointed ports.
#
# Arguments:
#       None.
#
# Results:
#       None.
#
# Side Effects:
#       Start serving for HTTP requests!
proc ::htinit {} {
    global H2M

    foreach p $H2M(-http) {
	set srv -1

	if { [string is integer -strict $p] } {
	    set srv [::http:init $p]
	} elseif { [string first ":" $p] >= 0 } {
	    foreach {proto port} [split $p ":"] break
	    switch -nocase -- $proto {
		"HTTP" {
		    set srv [::http:init $port]
		}
	    }
	}

	if { $srv > 0 } {
	    lappend H2M(servers) $srv
	}
    }
}


# ::debug -- Slave debug helper
#
#       This procedure is aliased into the slave interpreters. It arranges to
#       push the name of the "package" (in that case the source of the plugin)
#       at the beginning of the arguments. This is usefull to detect which
#       plugin is sending output and to select output from specific plugins in
#       larger projects via the -verbose command-line option.
#
# Arguments:
#	pkg	Name of package (will be name of plugin)
#	msg	Message
#	lvl	Debug level
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::debug { pkg msg {lvl "DEBUG"}} {
    toclbox log $lvl $msg $pkg
}


# ::plugin:init -- Initialise plugin facility
#
#       Loops through the specified routes to create and initialise
#       the requested plugins.  Each plugin filename will lead to the
#       creation of a safe interpreter with the same name.  The
#       content of the file will be sourced in the interpreter and the
#       interpreter will be donated a command called "stomp" that is
#       an alias for ::stomp::client::send and that can be used to
#       send data.
#
# Arguments:
#	mqtt	Identifier of MQTT client connection
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::plugin:init { stomp } {
    global H2M

    foreach { path route options } $H2M(-routes) {
        toclbox log info "Routing requests matching $path through $route"
	foreach {proc fname} [split $route "@"] break

        foreach dir $H2M(-exts) {
            set plugin [file join [toclbox resolve $dir [list appname $::appname]] $fname]

            if { [file exists $plugin] && [file type $plugin] eq "file" && ![dict exists $H2M(plugins) $fname] } {
                # Create slave interpreter and give it two commands to interact
                # with us: mqtt to send and debug to output some debugging
                # information.
                set slave [::safe::interpCreate $fname]
                $slave alias mqtt ::send
                $slave alias debug ::debug $fname
                # Automatically pass further all environment variables that
                # start with the same as the rootname of the plugin
                # implementation.
                ::toclbox::safe::environment $slave [string toupper [file rootname [file tail $plugin]]]*
                # Parse options and relay those into calls to island and/or
                # firewall modules
                foreach {opt value} $options {
                    switch -glob -- [string tolower [string trimleft $opt -]] {
                        "ac*" {
                            # -access enables access to local files or
                            # directories
                            ::toclbox::island::add $slave $value
                        }
                        "al*" {
                            # -allow enables access to remote servers
                            lassign [split $value :] host port
                            ::toclbox::firewall::allow $slave $host $port
                        }
                        "d*" {
                            # -deny refrains access to remote servers
                            lassign [split $value :] host port
                            ::toclbox::firewall::deny $slave $host $port
                        }
                        "p*" {
                            # -package arranges for the plugin to be able to
                            # access a given package.
                            lassign [split $value :] pkg version
                            switch -- $pkg {
                                "http" {
                                    toclbox log debug "Helping out package $pkg"
                                    ::toclbox::safe::environment $slave * "" tcl_platform
                                    ::toclbox::safe::alias $slave encoding ::toclbox::safe::invoke $slave encoding
                                }
                            }
                            ::toclbox::safe::package $slave $pkg $version
                        }
                        "e*" {
                            # -environement to pass environment variables.
                            ::toclbox::safe::environment $slave $value
                        }
                    }
                }
                toclbox log info "Loading plugin at $plugin"
                if { [catch {$slave invokehidden source $plugin} res] == 0 } {
                    # Remember fullpath to plugin, this will be used when data
                    # is coming in to select the slave to send data to. Without
                    # presence of the key in the dictionary, the HTTP receiving
                    # callback will not forward data.
                    dict set H2M(plugins) $fname $plugin
                } else {
                    toclbox log error "Cannot load plugin at $plugin: $res"
                }
                break;         # First match wins!
            }
        }
    }
    return ""

}



# Initialise MQTT connection and verbosity.
toclbox log notice "Connecting to MQTT server at $H2M(-host):$H2M(-port)"
set H2M(client) [mqtt new  \
                     -username $H2M(-user) \
                     -password $H2M(-password) \
                     -keepalive $H2M(-keepalive) \
                     -retransmit $H2M(-retransmit)]
$H2M(client) connect ${appname}-[pid] $H2M(-host) $H2M(-port)

# Read list of recognised plugins out from the routes.  Plugins are
# only to be found in the directory specified as part of the -exts
# option.  Each file will be sourced into a safe interpreter and will
# be given the command called "stomp" to be able to output to topics.
plugin:init $H2M(client)
# Initialise HTTP reception.  We can listen on several ports, but we
# will only listen to the path as specified through the routes.
htinit

vwait forever
