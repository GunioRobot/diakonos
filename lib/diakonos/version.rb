module Diakonos
  VERSION       = '0.9.1'
  LAST_MODIFIED = 'August 15, 2011'

  def self.parse_version( s )
    if s
      s.split( '.' ).map { |part| part.to_i }.extend( Comparable )
    end
  end

  def self.check_ruby_version
    ruby_version = parse_version( RUBY_VERSION )
    if ruby_version < [ 1, 9 ]
      $stderr.puts "This version of Diakonos (#{Diakonos::VERSION}) requires Ruby 1.9."
      if ruby_version >= [ 1, 8 ]
        $stderr.puts "Version 0.8.9 is the last version of Diakonos which can run under Ruby 1.8."
      end
      exit 1
    end
  end
end
