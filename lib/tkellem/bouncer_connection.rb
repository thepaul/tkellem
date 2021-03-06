require 'eventmachine'
require 'tkellem/irc_line'
require 'tkellem/backlog'

module Tkellem

module BouncerConnection
  include EM::Protocols::LineText2
  include Tkellem::EasyLogger

  def initialize(bouncer, do_ssl)
    set_delimiter "\r\n"

    @ssl = do_ssl
    @bouncer = bouncer

    @irc_server = nil
    @backlog = nil
    @nick = nil
    @conn_name = nil
    @name = nil
  end
  attr_reader :ssl, :irc_server, :backlog, :bouncer, :nick

  def connected?
    !!irc_server
  end

  def name
    @name || "new-conn"
  end

  def post_init
    if ssl
      debug "starting TLS"
      start_tls :verify_peer => false
    end
  end

  def ssl_handshake_completed
    debug "TLS complete"
  end

  def error!(msg)
    info("ERROR :#{msg}")
    send_msg("ERROR :#{msg}")
    close_connection(true)
  end

  def connect(conn_name, client_name, password)
    @irc_server = bouncer.get_irc_server(conn_name.downcase)
    unless irc_server && irc_server.connected?
      error!("unknown connection #{conn_name}")
      return
    end

    unless bouncer.do_auth(@nick, @password, irc_server)
      error!("bad auth, please check your password")
      @irc_server = @conn_name = @name = @backlog = nil
      return
    end

    @conn_name = conn_name
    @name = client_name
    @backlog = irc_server.bouncer_connect(self)
    unless backlog
      error!("unknown client #{client_name}")
      @irc_server = @conn_name = @name = nil
      return
    end

    info "connected"

    irc_server.send_welcome(self)
    backlog.send_backlog(self)
    irc_server.rooms.each { |room| simulate_join(room) }
  end

  def tkellem(msg)
    case msg.args.first
    when /nothing_yet/i
    else
      send_msg(":tkellem!tkellem@tkellem PRIVMSG #{nick} :Unknown tkellem command #{msg.args.first}")
    end
  end

  def receive_line(line)
    trace "from client: #{line}"
    msg = IrcLine.parse(line)
    case msg.command
    when /tkellem/i
      tkellem(msg)
    when /pass/i
      @password = msg.args.first
    when /user/i
      @conn_name, @client_name = msg.args.last.strip.split(' ')
    when /nick/i
      if connected?
        irc_server.change_nick(msg.last)
      else
        @nick = msg.last
        connect(@conn_name, @client_name, @password)
      end
    when /quit/i
      # DENIED
      close_connection
    when /ping/i
      send_msg(":tkellem PONG tkellem :#{msg.last}")
    else
      if !connected?
        close_connection
      else
        # pay it forward
        irc_server.send_msg(msg)
      end
    end
  end

  def simulate_join(room)
    send_msg(":#{irc_server.nick}!#{name}@tkellem JOIN #{room}")
    # TODO: intercept the NAMES response so that only this bouncer gets it
    # Otherwise other clients might show an "in this room" line.
    irc_server.send_msg("NAMES #{room}\r\n")
  end

  def transient_response(msg)
    send_msg(msg)
    if msg.command == "366"
      # finished joining this room, let's backlog it
      debug "got final NAMES for #{msg.args[1]}, sending backlog"
      backlog.send_backlog(self, msg.args[1])
    end
  end

  def send_msg(msg)
    trace "to client: #{msg}"
    send_data("#{msg}\r\n")
  end

  def log_name
    "#{@conn_name}-#{name}"
  end

  def unbind
    irc_server.bouncer_disconnect(self) if connected?
  end
end

end
