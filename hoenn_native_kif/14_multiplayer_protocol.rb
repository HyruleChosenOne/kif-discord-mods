# Transport-independent map authority and encounter reservations. No game objects
# or remote code cross the wire. KIF checks and rate limits the JSON envelope.
module HoennMultiplayer
  ID = :hoenn_mod_multiplayer
  PROTOCOL = 1
  LIMIT = 48
  class Room
    attr_reader :slot, :map, :peers, :epoch, :claims, :pending
    attr_accessor :emit, :grant, :available, :removed, :packet, :members
    def initialize(slot,nonce)
      @slot=slot; @nonce=nonce; @generation=0; @map=0
      @peers={}; @members=[]; @claims={}; @pending={}; @serial=0
      @seen={}; @granted={}; @epoch=""; @leader=nil
    end
    def enter(map)
      return if @map==map
      @map=map; @generation+=1; @epoch="#{@nonce}-#{@generation}"
      reset_claims
    end
    def reset_claims
      @claims.clear; @pending.clear; @seen.clear; @granted.clear
    end
    def leader
      ([slot]+@members.select { |s| @peers[s] && @peers[s]['m']==map }).min
    end
    def authority?; leader==slot; end
    def term; authority? ? epoch : (@peers[leader] || {})['e']; end
    def hello(follower)
      {'v'=>PROTOCOL,'m'=>map,'e'=>epoch,'f'=>follower}
    end
    def say(key,data,to=nil)
      envelope=data.merge('v'=>PROTOCOL,'m'=>map,'e'=>term)
      if to==slot
        receive(key,envelope,slot)
        true
      else
        @emit.call(key,envelope,to)
      end
    end
    def request(uid,kind,version=nil)
      @serial+=1; req="#{epoch}-#{@serial}"
      @pending[req]=[uid,kind]
      unless say('take',{'u'=>uid,'r'=>req,'k'=>kind,'z'=>version},leader)
        @pending.delete(req)
        return nil
      end
      req
    end
    def finish(req,consume=false)
      row=@pending.delete(req)
      @granted.delete(req)
      say('done',{'u'=>row[0],'r'=>req,'c'=>consume},leader) if row
    end
    def receive(key,d,from)
      return unless d.is_a?(Hash) && d['v']==PROTOCOL
      return unless from==slot || @members.include?(from)
      if key=='hello'
        return unless d['m'].is_a?(Integer) && d['m'].between?(1,100_000)
        return unless token?(d['e'])
        @peers[from]=d
        return
      end
      return unless d['m']==map && d['e']==term
      uid=d['u']; req=d['r']
      case key
      when 'take'
        return unless authority? && token?(uid) && token?(req) && %w[battle auto].include?(d['k'])
        return unless from==slot || (@peers[from] && @peers[from]['m']==map)
        # Idempotent retries, but never issue a second grant after completion.
        accepted=@claims[uid]==[from,req]
        unless accepted || @seen[req]
          accepted=!@claims.key?(uid) && @available.call(uid,d['z'])
          @claims[uid]=[from,req] if accepted
          @seen[req]=true
        end
        say('grant',{'u'=>uid,'r'=>req,'who'=>from,'ok'=>!!accepted})
        receive('grant',d.merge('who'=>from,'ok'=>!!accepted),slot) if from==slot
      when 'grant'
        return unless from==leader && d['who']==slot && token?(req)
        row=@pending[req]
        return unless row && row[0]==uid
        if d['ok']==true
          return if @granted[req]
          @granted[req]=true
          @grant.call(req,uid,row[1])
        else
          @pending.delete(req); @grant.call(req,uid,'denied')
        end
      when 'done'
        return unless authority? && @claims[uid]==[from,req]
        @claims.delete(uid)
        @removed.call(uid) if d['c']==true
      else
        @packet.call(key,d,from) if from==leader
      end
    end
    def prune
      @peers.delete_if { |s,_| !@members.include?(s) }
      @claims.delete_if { |_,(s,_)| s!=slot && (!@members.include?(s) || !@peers[s] || @peers[s]['m']!=map) }
      # Bounds replay bookkeeping to this map population/session.
      @seen.shift while @seen.size>1024
    end
    def token?(value); value.is_a?(String) && value.match?(/\A[0-9A-Za-z_-]{1,100}\z/); end
  end
end
