#!/usr/bin/env ruby

# == Diakonos
#
# A usable console text editor.
# :title: Diakonos
#
# Author:: Pistos (irc.freenode.net)
# http://purepistos.net/diakonos
# Copyright (c) 2004-2008 Pistos
#
# This software is released under the MIT licence.
# See the LICENCE file included with this program, or
# http://www.opensource.org/licenses/mit-license.php
#
require 'curses'
require 'open3'
require 'thread'
require 'English'
require 'set'

require 'diakonos/object'
require 'diakonos/enumerable'
require 'diakonos/regexp'
require 'diakonos/sized-array'
require 'diakonos/hash'
require 'diakonos/buffer-hash'
require 'diakonos/array'
require 'diakonos/string'
require 'diakonos/fixnum'
require 'diakonos/bignum'

require 'diakonos/functions'
require 'diakonos/keycode'
require 'diakonos/text-mark'
require 'diakonos/bookmark'
require 'diakonos/ctag'
require 'diakonos/finding'
require 'diakonos/buffer'
require 'diakonos/window'
require 'diakonos/clipboard'
require 'diakonos/readline'

#$profiling = true

#if $profiling
  #require 'ruby-prof'
#end

module Diakonos
  
  VERSION       = '0.8.7'
  LAST_MODIFIED = 'November 5, 2008'
  
  DONT_ADJUST_ROW       = false
  ADJUST_ROW            = true
  PROMPT_OVERWRITE      = true
  DONT_PROMPT_OVERWRITE = false
  DO_REDRAW             = true
  DONT_REDRAW           = false
  QUIET                 = true
  NOISY                 = false
  
  TAB       = 9
  ENTER     = 13
  ESCAPE    = 27
  BACKSPACE = 127
  CTRL_C    = 3
  CTRL_D    = 4
  CTRL_K    = 11
  CTRL_Q    = 17
  CTRL_H    = 263
  RESIZE2   = 4294967295
  
  DEFAULT_TAB_SIZE = 8
  
  CHOICE_NO           = 0
  CHOICE_YES          = 1
  CHOICE_ALL          = 2
  CHOICE_CANCEL       = 3
  CHOICE_YES_TO_ALL   = 4
  CHOICE_NO_TO_ALL    = 5
  CHOICE_YES_AND_STOP = 6
  CHOICE_KEYS = [
    [ ?n, ?N ],
    [ ?y, ?Y ],
    [ ?a, ?A ],
    [ ?c, ?C, ESCAPE, CTRL_C, CTRL_D, CTRL_Q ],
    [ ?e ],
    [ ?o ],
    [ ?s ],
  ]
  CHOICE_STRINGS = [ '(n)o', '(y)es', '(a)ll', '(c)ancel', 'y(e)s to all', 'n(o) to all', 'yes and (s)top' ]
  
  BOL_ZERO           = 0
  BOL_FIRST_CHAR     = 1
  BOL_ALT_ZERO       = 2
  BOL_ALT_FIRST_CHAR = 3
  
  EOL_END           = 0
  EOL_LAST_CHAR     = 1
  EOL_ALT_END       = 2
  EOL_ALT_LAST_CHAR = 3
  
  FORCE_REVERT = true
  ASK_REVERT   = false
  
  ASK_REPLACEMENT = true
  
  CASE_SENSITIVE   = true
  CASE_INSENSITIVE = false
  
  LANG_TEXT = 'text'
  
  NUM_LAST_COMMANDS = 2
    
  class Diakonos
    
    attr_reader :win_main, :settings, :token_regexps, :close_token_regexps,
      :token_formats, :diakonos_home, :script_dir, :diakonos_conf, :display_mutex,
      :indenters, :unindenters, :closers, :clipboard, :do_display,
      :current_buffer, :list_filename, :hooks, :last_commands, :there_was_non_movement

    include ::Diakonos::Functions

    def initialize( argv = [] )
      @diakonos_home = ( ( ENV[ 'HOME' ] or '' ) + '/.diakonos' ).subHome
      mkdir @diakonos_home
      @script_dir = "#{@diakonos_home}/scripts"
      mkdir @script_dir
      
      init_help
      
      @debug          = File.new( "#{@diakonos_home}/debug.log", 'w' )
      @list_filename  = @diakonos_home + '/listing.txt'
      @diff_filename  = @diakonos_home + '/text.diff'
      @help_filename  = "#{@help_dir}/about-help.dhf"
      @error_filename = "#{@diakonos_home}/diakonos.err"
      
      @files = Array.new
      @read_only_files = Array.new
      @config_filename = nil
      
      parseOptions argv
      
      @session_settings = Hash.new
      @win_main        = nil
      @win_context     = nil
      @win_status      = nil
      @win_interaction = nil
      @buffers = BufferHash.new
      
      loadConfiguration
      
      @quitting = false
      @untitled_id = 0
      
      @x = 0
      @y = 0
      
      @buffer_stack = Array.new
      @current_buffer = nil
      @buffer_history = Array.new
      @buffer_history_pointer = nil
      @bookmarks = Hash.new
      @macro_history = nil
      @macro_input_history = nil
      @macros = Hash.new
      @last_commands = SizedArray.new( NUM_LAST_COMMANDS )
      @playing_macro = false
      @display_mutex = Mutex.new
      @display_queue_mutex = Mutex.new
      @display_queue = nil
      @do_display = true
      @iline_mutex = Mutex.new
      @tag_stack = Array.new
      @last_search_regexps = nil
      @iterated_choice = nil
      @choice_iterations = 0
      @there_was_non_movement = false
      @status_vars = Hash.new
      
      # Readline histories
      @rlh_general = Array.new
      @rlh_files   = Array.new
      @rlh_search  = Array.new
      @rlh_shell   = Array.new
      @rlh_help    = Array.new
    end
    
    def mkdir( dir )
      if not FileTest.exists? dir
        Dir.mkdir dir
      end
    end

    def parseOptions( argv )
      @post_load_script = ""
      while argv.length > 0
        arg = argv.shift
        case arg
        when '-h', '--help'
          printUsage
          exit 1
        when '-ro'
          filename = argv.shift
          if filename.nil?
            printUsage
            exit 1
          else
            @read_only_files.push filename
          end
        when '-c', '--config'
          @config_filename = argv.shift
          if @config_filename.nil?
            printUsage
            exit 1
          end
        when '-e', '--execute'
          post_load_script = argv.shift
          if post_load_script.nil?
            printUsage
            exit 1
          else
            @post_load_script << "\n#{post_load_script}"
          end                        
        when '-m', '--open-matching'
          regexp = argv.shift
          files = `egrep -rl '#{regexp}' *`.split( /\n/ )
          if files.any?
            @files.concat files
            script = "\nfind 'down', CASE_SENSITIVE, '#{regexp}'"
            @post_load_script << script
          end              
        else
          # a name of a file to open
          @files.push arg
        end
      end
    end
    protected :parseOptions

    def printUsage
      puts "Usage: #{$0} [options] [file] [file...]"
      puts "\t--help\tDisplay usage"
      puts "\t-c <config file>\tLoad this config file instead of ~/.diakonos/diakonos.conf"
      puts "\t-e, --execute <Ruby code>\tExecute Ruby code (such as Diakonos commands) after startup"
      puts "\t-m, --open-matching <regular expression>\tOpen all matching files under current directory"
      puts "\t-ro <file>\tLoad file as read-only"
    end
    protected :printUsage
    
    def init_help
      @base_help_dir = "#{@diakonos_home}/help"
      mkdir @base_help_dir
      
      @help_dir = "#{@diakonos_home}/help/#{VERSION}"
      if not File.exist?( @help_dir )
        puts "Help files for this Diakonos version were not found (#{@help_dir})."
        
        $stdout.puts "Would you like to download the help files right now from the Diakonos website? (y/n)"; $stdout.flush
        answer = $stdin.gets
        case answer
        when /^y/i
          if not fetch_help
            $stderr.puts "Failed to get help for version #{VERSION}."
          end
        end
        
        if not FileTest.exists?( @help_dir ) or Dir[ "#{@help_dir}/*" ].size == 0
          $stderr.puts "Terminating..."
          exit 1
        end
      end
      
      @help_tags = `grep -h Tags #{@help_dir}/* | cut -d ' ' -f 2-`.split.uniq
    end
    
    def fetch_help
      require 'open-uri'
      success = false
      puts "Fetching help documents for version #{VERSION}..."
      
      filename = "diakonos-help-#{VERSION}.tar.gz"
      uri = "http://purepistos.net/diakonos/#{filename}"
      tarball = "#{@base_help_dir}/#{filename}"
      begin
        open( uri ) do |http|
          bytes = http.read
          File.open( tarball, 'w' ) do |f|
            f.print bytes
          end
        end
        mkdir @help_dir
        `tar zxf #{tarball} -C #{@base_help_dir}`
        success = true
      rescue OpenURI::HTTPError => e
        $stderr.puts "Failed to fetch from #{uri} ."
      end
      
      success
    end
    
    def initializeDisplay
      @win_main.close if @win_main
      @win_status.close if @win_status
      @win_interaction.close if @win_interaction
      @win_context.close if @win_context
      
      Curses::init_screen
      Curses::nonl
      Curses::raw
      Curses::noecho
      
      if Curses::has_colors?
        Curses::start_color
        Curses::init_pair( Curses::COLOR_BLACK, Curses::COLOR_BLACK, Curses::COLOR_BLACK )
        Curses::init_pair( Curses::COLOR_RED, Curses::COLOR_RED, Curses::COLOR_BLACK )
        Curses::init_pair( Curses::COLOR_GREEN, Curses::COLOR_GREEN, Curses::COLOR_BLACK )
        Curses::init_pair( Curses::COLOR_YELLOW, Curses::COLOR_YELLOW, Curses::COLOR_BLACK )
        Curses::init_pair( Curses::COLOR_BLUE, Curses::COLOR_BLUE, Curses::COLOR_BLACK )
        Curses::init_pair( Curses::COLOR_MAGENTA, Curses::COLOR_MAGENTA, Curses::COLOR_BLACK )
        Curses::init_pair( Curses::COLOR_CYAN, Curses::COLOR_CYAN, Curses::COLOR_BLACK )
        Curses::init_pair( Curses::COLOR_WHITE, Curses::COLOR_WHITE, Curses::COLOR_BLACK )
        @colour_pairs.each do |cp|
          Curses::init_pair( cp[ :number ], cp[ :fg ], cp[ :bg ] )
        end
      end
      
      @win_main = Curses::Window.new( main_window_height, Curses::cols, 0, 0 )
      @win_main.keypad( true )
      @win_status = Curses::Window.new( 1, Curses::cols, Curses::lines - 2, 0 )
      @win_status.keypad( true )
      @win_status.attrset @settings[ 'status.format' ]
      @win_interaction = Curses::Window.new( 1, Curses::cols, Curses::lines - 1, 0 )
      @win_interaction.keypad( true )
      
      if @settings[ 'context.visible' ]
        if @settings[ 'context.combined' ]
          pos = 1
        else
          pos = 3
        end
        @win_context = Curses::Window.new( 1, Curses::cols, Curses::lines - pos, 0 )
        @win_context.keypad( true )
      else
        @win_context = nil
      end
      
      @win_interaction.refresh
      @win_main.refresh
      
      @buffers.each_value do |buffer|
        buffer.reset_win_main
      end
    end
    
    def fetch_conf( location = "v#{VERSION}" )
      require 'open-uri'
      found = false
      puts "Fetching configuration from #{location}..."
      
      begin
        open( "http://github.com/Pistos/diakonos/tree/#{location}/diakonos.conf?raw=true" ) do |http|
          text = http.read
          if text =~ /key/ and text =~ /colour/ and text =~ /lang/
            found = true
            File.open( @diakonos_conf, 'w' ) do |f|
              f.puts text
            end
          end
        end
      rescue OpenURI::HTTPError => e
        $stderr.puts "Failed to fetch from #{location}."
      end
      
      found
    end
    
    def loadConfiguration
      # Set defaults first
      
      existent = 0
      conf_dirs = [
        '/usr/local/etc/diakonos.conf',
        '/usr/etc/diakonos.conf',
        '/etc/diakonos.conf',
        '/usr/local/share/diakonos/diakonos.conf',
        '/usr/share/diakonos/diakonos.conf'
      ]
      
      conf_dirs.each do |conf_dir|
        @global_diakonos_conf = conf_dir
        if FileTest.exists? @global_diakonos_conf
          existent += 1
          break
        end
      end
      
      @diakonos_conf = ( @config_filename or ( @diakonos_home + '/diakonos.conf' ) )
      existent += 1 if FileTest.exists? @diakonos_conf
      
      if existent < 1
        puts "diakonos.conf not found in any of:"
        conf_dirs.each do |conf_dir|
          puts "   #{conf_dir}"
        end
        puts "   ~/.diakonos/"
        puts "At least one configuration file must exist."
        $stdout.puts "Would you like to download one right now from the Diakonos repository? (y/n)"; $stdout.flush
        answer = $stdin.gets
        case answer
        when /^y/i
          if not fetch_conf
            fetch_conf 'master'
          end
        end
        
        if not FileTest.exists?( @diakonos_conf )
          puts "Terminating..."
          exit 1
        end
      end
      
      @logfilename = @diakonos_home + "/diakonos.log"
      @keychains           = Hash.new
      @token_regexps       = Hash.new
      @close_token_regexps = Hash.new
      @token_formats       = Hash.new
      @indenters           = Hash.new
      @unindenters         = Hash.new
      @filemasks           = Hash.new
      @bangmasks           = Hash.new
      @closers             = Hash.new
      
      @settings = Hash.new
      # Setup some defaults
      @settings[ "context.format" ] = Curses::A_REVERSE
      
      @keychains[ Curses::KEY_RESIZE ] = [ "redraw", nil ]
      @keychains[ RESIZE2 ] = [ "redraw", nil ]
      
      @colour_pairs = Array.new
      
      begin
        parseConfigurationFile( @global_diakonos_conf )
        parseConfigurationFile( @diakonos_conf )
        
        # Session settings override config file settings.
        
        @session_settings.each do |key,value|
          @settings[ key ] = value
        end
        
        @clipboard = Clipboard.new @settings[ "max_clips" ]
        @log = File.open( @logfilename, "a" )
        
        if @buffers
          @buffers.each_value do |buffer|
            buffer.configure
          end
        end
      rescue Errno::ENOENT
        # No config file found or readable
      end
    end
    
    def parseConfigurationFile( filename )
      return if not FileTest.exists? filename
      
      lines = IO.readlines( filename ).collect { |l| l.chomp }
      lines.each do |line|
        # Skip comments
        next if line[ 0 ] == ?#
        
        command, arg = line.split( /\s+/, 2 )
        next if command.nil?
        command = command.downcase
        case command
        when "include"
          parseConfigurationFile arg.subHome
        when "key"
          if arg
            if /  / === arg
              keystrings, function_and_args = arg.split( / {2,}/, 2 )
            else
              keystrings, function_and_args = arg.split( /;/, 2 )
            end
            keystrokes = Array.new
            keystrings.split( /\s+/ ).each do |ks_str|
              code = ks_str.keyCode
              if code
                keystrokes.concat code
              else
                puts "unknown keystring: #{ks_str}"
              end
            end
            if function_and_args.nil?
              @keychains.deleteKeyPath( keystrokes )
            else
              function, function_args = function_and_args.split( /\s+/, 2 )
              @keychains.setKeyPath(
                keystrokes,
                [ function, function_args ]
              )
            end
          end
        when /^lang\.(.+?)\.tokens\.([^.]+)(\.case_insensitive)?$/
          getTokenRegexp( @token_regexps, arg, Regexp.last_match )
        when /^lang\.(.+?)\.tokens\.([^.]+)\.open(\.case_insensitive)?$/
          getTokenRegexp( @token_regexps, arg, Regexp.last_match )
        when /^lang\.(.+?)\.tokens\.([^.]+)\.close(\.case_insensitive)?$/
          getTokenRegexp( @close_token_regexps, arg, Regexp.last_match )
        when /^lang\.(.+?)\.tokens\.(.+?)\.format$/
          language = $1
          token_class = $2
          @token_formats[ language ] = ( @token_formats[ language ] or Hash.new )
          @token_formats[ language ][ token_class ] = arg.toFormatting
        when /^lang\.(.+?)\.format\..+$/
          @settings[ command ] = arg.toFormatting
        when /^colou?r$/
          number, fg, bg = arg.split( /\s+/ )
          number = number.to_i
          fg = fg.toColourConstant
          bg = bg.toColourConstant
          @colour_pairs << {
            :number => number,
            :fg => fg,
            :bg => bg
          }
        when /^lang\.(.+?)\.indent\.indenters(\.case_insensitive)?$/
          case_insensitive = ( $2 != nil )
          if case_insensitive
            @indenters[ $1 ] = Regexp.new( arg, Regexp::IGNORECASE )
          else
            @indenters[ $1 ] = Regexp.new arg
          end
        when /^lang\.(.+?)\.indent\.unindenters(\.case_insensitive)?$/
          case_insensitive = ( $2 != nil )
          if case_insensitive
            @unindenters[ $1 ] = Regexp.new( arg, Regexp::IGNORECASE )
          else
            @unindenters[ $1 ] = Regexp.new arg
          end
        when /^lang\.(.+?)\.indent\.preventers(\.case_insensitive)?$/,
          /^lang\.(.+?)\.indent\.ignore(\.case_insensitive)?$/,
          /^lang\.(.+?)\.context\.ignore(\.case_insensitive)?$/
          case_insensitive = ( $2 != nil )
          if case_insensitive
            @settings[ command ] = Regexp.new( arg, Regexp::IGNORECASE )
          else
            @settings[ command ] = Regexp.new arg
          end
        when /^lang\.(.+?)\.filemask$/
          @filemasks[ $1 ] = Regexp.new arg
        when /^lang\.(.+?)\.bangmask$/
          @bangmasks[ $1 ] = Regexp.new arg
        when /^lang\.(.+?)\.closers\.(.+?)\.(.+?)$/
          @closers[ $1 ] ||= Hash.new
          @closers[ $1 ][ $2 ] ||= Hash.new
          @closers[ $1 ][ $2 ][ $3.to_sym ] = case $3
        when 'regexp'
          Regexp.new arg
        when 'closer'
          begin
            eval( "Proc.new " + arg )
          rescue Exception => e
            showException(
              e,
              [
                "Failed to process Proc for #{command}.",
              ]
            )
          end
        end
        when "context.visible", "context.combined", "eof_newline", "view.nonfilelines.visible",
          /^lang\.(.+?)\.indent\.(?:auto|roundup|using_tabs|closers)$/,
          "found_cursor_start", "convert_tabs", 'delete_newline_on_delete_to_eol',
          'suppress_welcome'
          @settings[ command ] = arg.to_b
        when "context.format", "context.separator.format", "status.format"
          @settings[ command ] = arg.toFormatting
        when "logfile"
          @logfilename = arg.subHome
        when "context.separator", "status.left", "status.right", "status.filler",
          "status.modified_str", "status.unnamed_str", "status.selecting_str",
          "status.read_only_str", /^lang\..+?\.indent\.ignore\.charset$/,
          /^lang\.(.+?)\.tokens\.([^.]+)\.change_to$/,
          /^lang\.(.+?)\.column_delimiters$/,
          "view.nonfilelines.character",
          'interaction.blink_string', 'diff_command'
          @settings[ command ] = arg
        when /^lang\..+?\.comment_(?:close_)?string$/
          @settings[ command ] = arg.gsub( /^["']|["']$/, '' )
        when "status.vars"
          @settings[ command ] = arg.split( /\s+/ )
        when /^lang\.(.+?)\.indent\.size$/, /^lang\.(.+?)\.(?:tabsize|wrap_margin)$/
          @settings[ command ] = arg.to_i
        when "context.max_levels", "context.max_segment_width", "max_clips", "max_undo_lines",
          "view.margin.x", "view.margin.y", "view.scroll_amount", "view.lookback"
          @settings[ command ] = arg.to_i
        when "view.jump.x", "view.jump.y"
          value = arg.to_i
          if value < 1
            value = 1
          end
          @settings[ command ] = value
        when "bol_behaviour", "bol_behavior"
          case arg.downcase
          when "zero"
            @settings[ "bol_behaviour" ] = BOL_ZERO
          when "first-char"
            @settings[ "bol_behaviour" ] = BOL_FIRST_CHAR
          when "alternating-zero"
            @settings[ "bol_behaviour" ] = BOL_ALT_ZERO
          else # default
            @settings[ "bol_behaviour" ] = BOL_ALT_FIRST_CHAR
          end
        when "eol_behaviour", "eol_behavior"
          case arg.downcase
          when "end"
            @settings[ "eol_behaviour" ] = EOL_END
          when "last-char"
            @settings[ "eol_behaviour" ] = EOL_LAST_CHAR
          when "alternating-last-char"
            @settings[ "eol_behaviour" ] = EOL_ALT_FIRST_CHAR
          else # default
            @settings[ "eol_behaviour" ] = EOL_ALT_END
          end
        when "context.delay", 'interaction.blink_duration', 'interaction.choice_delay'
          @settings[ command ] = arg.to_f
        end
      end
    end
    protected :parseConfigurationFile

    def getTokenRegexp( hash, arg, match )
      language = match[ 1 ]
      token_class = match[ 2 ]
      case_insensitive = ( match[ 3 ] != nil )
      hash[ language ] = ( hash[ language ] or Hash.new )
      if case_insensitive
        hash[ language ][ token_class ] = Regexp.new( arg, Regexp::IGNORECASE )
      else
        hash[ language ][ token_class ] = Regexp.new arg
      end
    end

    def redraw
      loadConfiguration
      initializeDisplay
      updateStatusLine
      updateContextLine
      @current_buffer.display
    end
    
    def log( string )
      @log.puts string
      @log.flush
    end
    
    def debugLog( string )
      @debug.puts( Time.now.strftime( "[%a %H:%M:%S] #{string}" ) )
      @debug.flush
    end
    
    def register_proc( the_proc, hook_name, priority = 0 )
      @hooks[ hook_name ] << { :proc => the_proc, :priority => priority }
    end
    
    def clearNonMovementFlag
      @there_was_non_movement = false
    end
    
    # -----------------------------------------------------------------------

    def main_window_height
      # One line for the status line
      # One line for the input line
      # One line for the context line
      retval = Curses::lines - 2
      if @settings[ "context.visible" ] and not @settings[ "context.combined" ]
        retval = retval - 1
      end
      retval
    end
    
    def main_window_width
      Curses::cols
    end
    
    def start
      initializeDisplay
      
      @hooks = {
        :after_buffer_switch => [],
        :after_open          => [],
        :after_save          => [],
        :after_startup       => [],
      }
      Dir[ "#{@script_dir}/*" ].each do |script|
        begin
          require script
        rescue Exception => e
          showException(
            e,
            [
              "There is a syntax error in the script.",
              "An invalid hook name was used."
            ]
          )
        end
      end
      @hooks.each do |hook_name, hook|
        hook.sort { |a,b| a[ :priority ] <=> b[ :priority ] }
      end

      if ENV[ 'COLORTERM' ] == 'gnome-terminal'
        help_key = 'Shift-F1'
      else
        help_key = 'F1'
      end
      setILine "Diakonos #{VERSION} (#{LAST_MODIFIED})   #{help_key} for help  F12 to configure  Ctrl-Q to quit"
      
      num_opened = 0
      if @files.length == 0 and @read_only_files.length == 0
        num_opened += 1 if openFile
      else
        @files.each do |file|
          num_opened += 1 if openFile file
        end
        @read_only_files.each do |file|
          num_opened += 1 if openFile( file, Buffer::READ_ONLY )
        end
      end
      
      if num_opened > 0
        switchToBufferNumber 1
        
        updateStatusLine
        updateContextLine
        
        if @post_load_script
          eval @post_load_script
        end
        
        runHookProcs :after_startup
        
        if not @settings[ 'suppress_welcome' ]
          openFile "#{@help_dir}/welcome.dhf"
        end
        
        begin
          # Main keyboard loop.
          while not @quitting
            processKeystroke
            @win_main.refresh
          end
        rescue SignalException => e
          debugLog "Terminated by signal (#{e.message})"
        end
        
        @debug.close
      end
    end
    
    def capture_keychain( c, context )
      if c == ENTER
        @capturing_keychain = false
        @current_buffer.deleteSelection
        str = context.to_keychain_s.strip
        @current_buffer.insertString str 
        cursorRight( Buffer::STILL_TYPING, str.length )
      else
        keychain_pressed = context.concat [ c ]
        
        function_and_args = @keychains.getLeaf( keychain_pressed )
        
        if function_and_args
          function, args = function_and_args
        end
        
        partial_keychain = @keychains.getNode( keychain_pressed )
        if partial_keychain
          setILine( "Part of existing keychain: " + keychain_pressed.to_keychain_s + "..." )
        else
          setILine keychain_pressed.to_keychain_s + "..."
        end
        processKeystroke( keychain_pressed )
      end
    end
    
    def capture_mapping( c, context )
      if c == ENTER
        @capturing_mapping = false
        @current_buffer.deleteSelection
        setILine
      else
        keychain_pressed = context.concat [ c ]
        
        function_and_args = @keychains.getLeaf( keychain_pressed )
        
        if function_and_args
          function, args = function_and_args
          setILine "#{keychain_pressed.to_keychain_s.strip}  ->  #{function}( #{args} )"
        else
          partial_keychain = @keychains.getNode( keychain_pressed )
          if partial_keychain
            setILine( "Several mappings start with: " + keychain_pressed.to_keychain_s + "..." )
            processKeystroke( keychain_pressed )
          else
            setILine "There is no mapping for " + keychain_pressed.to_keychain_s
          end
        end
      end
    end
    
    # context is an array of characters (bytes) which are keystrokes previously
    # typed (in a chain of keystrokes)
    def processKeystroke( context = [] )
      c = @win_main.getch
        
      if @capturing_keychain
        capture_keychain c, context
      elsif @capturing_mapping
        capture_mapping c, context
      else
        
        if context.empty?
          if c > 31 and c < 255 and c != BACKSPACE
            if @macro_history
              @macro_history.push "typeCharacter #{c}"
            end
            @there_was_non_movement = true
            typeCharacter c
            return
          end
        end
        keychain_pressed = context.concat [ c ]
            
        function_and_args = @keychains.getLeaf( keychain_pressed )
        
        if function_and_args
          function, args = function_and_args
          setILine if not @settings[ "context.combined" ]
          
          if args
            to_eval = "#{function}( #{args} )"
          else
            to_eval = function
          end
          
          if @macro_history
            @macro_history.push to_eval
          end
          
          begin
            eval to_eval, nil, "eval"
            @last_commands << to_eval unless to_eval == "repeatLast"
            if not @there_was_non_movement
              @there_was_non_movement = ( not to_eval.movement? )
            end
          rescue Exception => e
            debugLog e.message
            debugLog e.backtrace.join( "\n\t" )
            showException e
          end
        else
          partial_keychain = @keychains.getNode( keychain_pressed )
          if partial_keychain
            setILine( keychain_pressed.to_keychain_s + "..." )
            processKeystroke( keychain_pressed )
          else
            setILine "Nothing assigned to #{keychain_pressed.to_keychain_s}"
          end
        end
      end
    end
    protected :processKeystroke

    # Display text on the interaction line.
    def setILine( string = "" )
      Curses::curs_set 0
      @win_interaction.setpos( 0, 0 )
      @win_interaction.addstr( "%-#{Curses::cols}s" % string )
      @win_interaction.refresh
      Curses::curs_set 1
      string.length
    end
    
    def showClips
      clip_filename = @diakonos_home + "/clips.txt"
      File.open( clip_filename, "w" ) do |f|
        @clipboard.each do |clip|
          f.puts clip
          f.puts "---------------------------"
        end
      end
      openFile clip_filename
    end

    def switchTo( buffer )
      switched = false
      if buffer
        @buffer_stack -= [ @current_buffer ]
        if @current_buffer
          @buffer_stack.push @current_buffer
        end
        @current_buffer = buffer
        runHookProcs( :after_buffer_switch, buffer )
        updateStatusLine
        updateContextLine
        buffer.display
        switched = true
      end
      
      switched
    end
    protected :switchTo
    
    def remember_buffer( buffer )
      if @buffer_history.last != buffer
        @buffer_history << buffer
        @buffer_history_pointer = @buffer_history.size - 1
      end
    end
    
    def set_status_variable( identifier, value )
      @status_vars[ identifier ] = value
    end

    def buildStatusLine( truncation = 0 )
      var_array = Array.new
      @settings[ "status.vars" ].each do |var|
        case var
        when "buffer_number"
          var_array.push bufferToNumber( @current_buffer )
        when "col"
          var_array.push( @current_buffer.last_screen_col + 1 )
        when "filename"
          name = @current_buffer.nice_name
          var_array.push( name[ ([ truncation, name.length ].min)..-1 ] )
        when "modified"
          if @current_buffer.modified?
            var_array.push @settings[ "status.modified_str" ]
          else
            var_array.push ""
          end
        when "num_buffers"
          var_array.push @buffers.length
        when "num_lines"
          var_array.push @current_buffer.length
        when "row", "line"
          var_array.push( @current_buffer.last_row + 1 )
        when "read_only"
          if @current_buffer.read_only
            var_array.push @settings[ "status.read_only_str" ]
          else
            var_array.push ""
          end
        when "selecting"
          if @current_buffer.changing_selection
            var_array.push @settings[ "status.selecting_str" ]
          else
            var_array.push ""
          end
        when "type"
          var_array.push @current_buffer.original_language
        when /^@/
          var_array.push @status_vars[ var ]
        end
      end
      str = nil
      begin
        status_left = @settings[ "status.left" ]
        field_count = status_left.count "%"
        status_left = status_left % var_array[ 0...field_count ]
        status_right = @settings[ "status.right" ] % var_array[ field_count..-1 ]
        filler_string = @settings[ "status.filler" ]
        fill_amount = (Curses::cols - status_left.length - status_right.length) / filler_string.length
        if fill_amount > 0
          filler = filler_string * fill_amount
        else
          filler = ""
        end
        str = status_left + filler + status_right
      rescue ArgumentError => e
        str = "%-#{Curses::cols}s" % "(status line configuration error)"
      end
      str
    end
    protected :buildStatusLine

    def updateStatusLine
      str = buildStatusLine
      if str.length > Curses::cols
        str = buildStatusLine( str.length - Curses::cols )
      end
      Curses::curs_set 0
      @win_status.setpos( 0, 0 )
      @win_status.addstr str
      @win_status.refresh
      Curses::curs_set 1
    end

    def updateContextLine
      if @win_context
        @context_thread.exit if @context_thread
        @context_thread = Thread.new do ||
          
          context = @current_buffer.context
          
          Curses::curs_set 0
          @win_context.setpos( 0, 0 )
          chars_printed = 0
          if context.length > 0
            truncation = [ @settings[ "context.max_levels" ], context.length ].min
            max_length = [
              ( Curses::cols / truncation ) - @settings[ "context.separator" ].length,
              ( @settings[ "context.max_segment_width" ] or Curses::cols )
            ].min
            line = nil
            context_subset = context[ 0...truncation ]
            context_subset = context_subset.collect do |line|
              line.strip[ 0...max_length ]
            end
            
            context_subset.each do |line|
              @win_context.attrset @settings[ "context.format" ]
              @win_context.addstr line
              chars_printed += line.length
              @win_context.attrset @settings[ "context.separator.format" ]
              @win_context.addstr @settings[ "context.separator" ]
              chars_printed += @settings[ "context.separator" ].length
            end
          end
          
          @iline_mutex.synchronize do
            @win_context.attrset @settings[ "context.format" ]
            @win_context.addstr( " " * ( Curses::cols - chars_printed ) )
            @win_context.refresh
          end
          @display_mutex.synchronize do
            @win_main.setpos( @current_buffer.last_screen_y, @current_buffer.last_screen_x )
            @win_main.refresh
          end
          Curses::curs_set 1
        end
        
        @context_thread.priority = -2
      end
    end
    
    def displayEnqueue( buffer )
      @display_queue_mutex.synchronize do
        @display_queue = buffer
      end
    end
    
    def displayDequeue
      @display_queue_mutex.synchronize do
        if @display_queue
          Thread.new( @display_queue ) do |b|
            @display_mutex.lock
            @display_mutex.unlock
            b.display
          end
          @display_queue = nil
        end
      end
    end

    # completion_array is the array of strings that tab completion can use
    def getUserInput( prompt, history = @rlh_general, initial_text = "", completion_array = nil, &block )
      if @playing_macro
        retval = @macro_input_history.shift
      else
        retval = Readline.new( self, @win_interaction, prompt, initial_text, completion_array, history, &block ).readline
        if @macro_history
          @macro_input_history.push retval
        end
        setILine
      end
      retval
    end

    def getLanguageFromName( name )
      retval = nil
      @filemasks.each do |language,filemask|
        if name =~ filemask
          retval = language
          break
        end
      end
      retval
    end
    
    def getLanguageFromShaBang( first_line )
      retval = nil
      @bangmasks.each do |language,bangmask|
        if first_line =~ /^#!/ and first_line =~ bangmask
          retval = language
          break
        end
      end
      retval
    end
    
    def showException( e, probable_causes = [ "Unknown" ] )
      begin
        File.open( @error_filename, "w" ) do |f|
          f.puts "Diakonos Error:"
          f.puts
          f.puts e.message
          f.puts
          f.puts "Probable Causes:"
          f.puts
          probable_causes.each do |pc|
            f.puts "- #{pc}"
          end
          f.puts
          f.puts "----------------------------------------------------"
          f.puts "If you can reproduce this error, please report it at"
          f.puts "http://linis.purepistos.net/ticket/list/Diakonos !"
          f.puts "----------------------------------------------------"
          f.puts e.backtrace
        end
        openFile( @error_filename )
      rescue Exception => e2
        debugLog "EXCEPTION: #{e.message}"
        debugLog "\t#{e.backtrace}"
      end
    end
    
    def logBacktrace
      begin
        raise Exception
      rescue Exception => e
        e.backtrace[ 1..-1 ].each do |x|
          debugLog x
        end
      end
    end

    # The given buffer_number should be 1-based, not zero-based.
    # Returns nil if no such buffer exists.
    def bufferNumberToName( buffer_number )
      return nil if buffer_number < 1
      
      number = 1
      buffer_name = nil
      @buffers.each_key do |name|
        if number == buffer_number
          buffer_name = name
          break
        end
        number += 1
      end
      buffer_name
    end

    # The returned value is 1-based, not zero-based.
    # Returns nil if no such buffer exists.
    def bufferToNumber( buffer )
      number = 1
      buffer_number = nil
      @buffers.each_value do |b|
        if b == buffer
          buffer_number = number
          break
        end
        number += 1
      end
      buffer_number
    end

    def subShellVariables( string )
      return nil if string.nil?
      
      retval = string
      retval = retval.subHome
      
      # Current buffer filename
      retval.gsub!( /\$f/, ( $1 or "" ) + ( @current_buffer.name or "" ) )
      
      # space-separated list of all buffer filenames
      name_array = Array.new
      @buffers.each_value do |b|
        name_array.push b.name
      end
      retval.gsub!( /\$F/, ( $1 or "" ) + ( name_array.join(' ') or "" ) )
      
      # Get user input, sub it in
      if retval =~ /\$i/
        user_input = getUserInput( "Argument: ", @rlh_shell )
        retval.gsub!( /\$i/, user_input )
      end
      
      # Current clipboard text
      if retval =~ /\$c/
        clip_filename = @diakonos_home + "/clip.txt"
        File.open( clip_filename, "w" ) do |clipfile|
          if @clipboard.clip
            clipfile.puts( @clipboard.clip.join( "\n" ) )
          end
        end
        retval.gsub!( /\$c/, clip_filename )
      end
      
      # Current klipper (KDE clipboard) text
      if retval =~ /\$k/
        clip_filename = @diakonos_home + "/clip.txt"
        File.open( clip_filename, "w" ) do |clipfile|
          clipfile.puts( `dcop klipper klipper getClipboardContents` )
        end
        retval.gsub!( /\$k/, clip_filename )
      end
      
      # Currently selected text
      if retval =~ /\$s/
        text_filename = @diakonos_home + "/selected.txt"
        
        File.open( text_filename, "w" ) do |textfile|
          selected_text = @current_buffer.selected_text
          if selected_text
            textfile.puts( selected_text.join( "\n" ) )
          end
        end
        retval.gsub!( /\$s/, text_filename )
      end
      
      retval
    end
    
    def showMessage( message, non_interaction_duration = @settings[ 'interaction.choice_delay' ] )
      terminateMessage
      
      @message_expiry = Time.now + non_interaction_duration
      @message_thread = Thread.new do
        time_left = @message_expiry - Time.now
        while time_left > 0
          setILine "(#{time_left.round}) #{message}"
          @win_main.setpos( @saved_main_y, @saved_main_x )
          sleep 1
          time_left = @message_expiry - Time.now
        end
        setILine message
        @win_main.setpos( @saved_main_y, @saved_main_x )
      end
    end
    
    def terminateMessage
      if @message_thread and @message_thread.alive?
        @message_thread.terminate
        @message_thread = nil
      end
    end
    
    def interactionBlink( message = nil )
      terminateMessage
      setILine @settings[ 'interaction.blink_string' ]
      sleep @settings[ 'interaction.blink_duration' ]
      setILine message if message
    end
    
    # choices should be an array of CHOICE_* constants.
    # default is what is returned when Enter is pressed.
    def getChoice( prompt, choices, default = nil )
      retval = @iterated_choice
      if retval
        @choice_iterations -= 1
        if @choice_iterations < 1
          @iterated_choice = nil
          @do_display = true
        end
        return retval 
      end
      
      @saved_main_x = @win_main.curx
      @saved_main_y = @win_main.cury
      
      msg = prompt + " "
      choice_strings = choices.collect do |choice|
        CHOICE_STRINGS[ choice ]
      end
      msg << choice_strings.join( ", " )
      
      if default.nil?
        showMessage msg
      else
        setILine msg
      end
      
      c = nil
      while retval.nil?
        c = @win_interaction.getch
        
        case c
        when Curses::KEY_NPAGE
          pageDown
        when Curses::KEY_PPAGE
          pageUp
        else
          if @message_expiry and Time.now < @message_expiry
            interactionBlink
            showMessage msg
          else
            case c
            when ENTER
              retval = default
            when ?0..?9
              if @choice_iterations < 1
                @choice_iterations = ( c - ?0 )
              else
                @choice_iterations = @choice_iterations * 10 + ( c - ?0 )
              end
            else
              choices.each do |choice|
                if CHOICE_KEYS[ choice ].include? c
                  retval = choice
                  break
                end
              end
            end
            
            if retval.nil?
              interactionBlink( msg )
            end
          end
        end
      end
      
      terminateMessage
      setILine
      
      if @choice_iterations > 0
        @choice_iterations -= 1
        @iterated_choice = retval
        @do_display = false
      end
      
      retval
    end

    def startRecordingMacro( name = nil )
      return if @macro_history
      @macro_name = name
      @macro_history = Array.new
      @macro_input_history = Array.new
      setILine "Started macro recording."
    end
    protected :startRecordingMacro
    
    def stopRecordingMacro
      @macro_history.pop  # Remove the stopRecordingMacro command itself
      @macros[ @macro_name ] = [ @macro_history, @macro_input_history ]
      @macro_history = nil
      @macro_input_history = nil
      setILine "Stopped macro recording."
    end
    protected :stopRecordingMacro

    def typeCharacter( c )
      @current_buffer.deleteSelection( Buffer::DONT_DISPLAY )
      @current_buffer.insertChar c
      cursorRight( Buffer::STILL_TYPING )
    end
    
    def loadTags
      @tags = Hash.new
      if @current_buffer and @current_buffer.name
        path = File.expand_path( File.dirname( @current_buffer.name ) )
        tagfile = path + "/tags"
      else
        tagfile = "./tags"
      end
      if FileTest.exists? tagfile
        IO.foreach( tagfile ) do |line_|
          line = line_.chomp
          # <tagname>\t<filepath>\t<line number or regexp>\t<kind of tag>
          tag, file, command, kind, rest = line.split( /\t/ )
          command.gsub!( /;"$/, "" )
          if command =~ /^\/.*\/$/
            command = command[ 1...-1 ]
          end
          @tags[ tag ] ||= Array.new
          @tags[ tag ].push CTag.new( file, command, kind, rest )
        end
      else
        setILine "(tags file not found)"
      end
    end
    
    def refreshAll
      @win_main.refresh
      if @win_context
        @win_context.refresh
      end
      @win_status.refresh
      @win_interaction.refresh
    end
    
    def openListBuffer
      @list_buffer = openFile( @list_filename )
    end
    
    def closeListBuffer
      closeFile( @list_buffer )
      @list_buffer = nil
    end
    def showing_list?
      @list_buffer
    end
    def list_item_selected?
      @list_buffer and @list_buffer.selecting?
    end
    def current_list_item
      if @list_buffer
        @list_buffer.select_current_line
      end
    end
    def select_list_item
      if @list_buffer
        line = @list_buffer.select_current_line
        @list_buffer.display
        line
      end
    end
    def previous_list_item
      if @list_buffer
        cursorUp
        @list_buffer[ @list_buffer.currentRow ]
      end
    end
    def next_list_item
      if @list_buffer
        cursorDown
        @list_buffer[ @list_buffer.currentRow ]
      end
    end
    
    def open_help_buffer
      @help_buffer = openFile( @help_filename )
    end
    def close_help_buffer
      closeFile @help_buffer
      @help_buffer = nil
    end
    
    def runHookProcs( hook_id, *args )
      @hooks[ hook_id ].each do |hook_proc|
        hook_proc[ :proc ].call( *args )
      end
    end
    
    # --------------------------------------------------------------------
    #
    # Program Function helpers

    def write_to_clip_file( text )
      clip_filename = @diakonos_home + "/clip.txt"
      File.open( clip_filename, "w" ) do |f|
        f.print text
      end
      clip_filename
    end
    
    # Returns true iff some text was copied to klipper.
    def send_to_klipper( text )
      return false if text.nil?
      
      clip_filename = write_to_clip_file( text.join( "\n" ) )
      # A little shell sorcery to ensure the shell doesn't strip off trailing newlines.
      # Thank you to pgas from irc.freenode.net#bash for help with this.
      `clipping=$(cat #{clip_filename};printf "_"); dcop klipper klipper setClipboardContents "${clipping%_}"`
      true
    end

    # Worker method for find function.
    def find_( direction, case_sensitive, regexp_source, replacement, starting_row, starting_col, quiet )
      return if( regexp_source.nil? or regexp_source.empty? )
      
      rs_array = regexp_source.newlineSplit
      regexps = Array.new
      exception_thrown = nil
      
      rs_array.each do |source|
        begin
          warning_verbosity = $VERBOSE
          $VERBOSE = nil
          regexps << Regexp.new(
            source,
            case_sensitive ? nil : Regexp::IGNORECASE
          )
          $VERBOSE = warning_verbosity
        rescue RegexpError => e
          if not exception_thrown
            exception_thrown = e
            source = Regexp.escape( source )
            retry
          else
            raise e
          end
        end
      end
      
      if replacement == ASK_REPLACEMENT
        replacement = getUserInput( "Replace with: ", @rlh_search )
      end
      
      if exception_thrown and not quiet
        setILine( "Searching literally; #{exception_thrown.message}" )
      end
      
      @current_buffer.find(
        regexps,
        :direction    => direction,
        :replacement  => replacement,
        :starting_row => starting_row,
        :starting_col => starting_col,
        :quiet        => quiet
      )
      @last_search_regexps = regexps
    end

    def with_list_file
      File.open( @list_filename, "w" ) do |f|
        yield f
      end
    end
    
    def matching_help_documents( str )
      docs = []

      if str =~ %r{^/(.+)$}
        regexp = $1
        files = Dir[ "#{@help_dir}/*" ].select{ |f|
          File.open( f ) { |io| io.grep( /#{regexp}/i ) }.any?
        }
      else
        terms = str.gsub( /[^a-zA-Z0-9-]/, ' ' ).split.join( '|' )
        file_grep = `egrep -i -l '^Tags.*\\b(#{terms})\\b' #{@help_dir}/*`
        files = file_grep.split( /\s+/ )
      end
      
      files.each do |file|
        File.open( file ) do |f|
          docs << ( "%-300s | %s" % [ f.gets.strip, file ] )
        end
      end
      
      docs.sort { |a,b| a.gsub( /^# (?:an?|the) */i, '# ' ) <=> b.gsub( /^# (?:an?|the) */i, '# ' ) }
    end
    
    def open_help_document( selected_string )
      help_file = selected_string.split( "| " )[ -1 ]
      if File.exist? help_file
        openFile help_file
      end
    end
    
  end

end

if __FILE__ == $PROGRAM_NAME
  $diakonos = Diakonos::Diakonos.new( ARGV )
  $diakonos.start
end
