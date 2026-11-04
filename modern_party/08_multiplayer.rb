# Hoenn provides the shared-world protocol; Modern Party adds follower visuals
# and reservations for its auto attacks. No networking on older engines.
if defined?(KIF::Net::ModShare)
module KIFModernFollowerNet
  ID=:modern_party_followers
  @remotes={}; @peers={}; @last_send=-10; @serial=0
  def self.now; KIF::Net.now; end
  def self.session_changed
    s=KIF::Net.connected? ? KIF::Net.session : nil
    return if @session.equal?(s) && @global.equal?($PokemonGlobal)
    dispose_followers
    @session=s; @global=$PokemonGlobal; @peers={}
    @last_send=-10; @sent=nil; @serial=0
    @nonce=s ? KIF::Net::Crypto.random(6).unpack1('H*') : nil
  end
  def self.follower_map(id)
    return nil unless $MapFactory && $game_map
    return nil unless id==$game_map.map_id ||
      (defined?(KIF::Presence) && KIF::Presence.map_offset(id,$game_map.map_id))
    $MapFactory.getMapNoAdd(id)
  end
  def self.snapshot
    ev=KIFModernFieldBattle.follower; mon=KIFModernFollower.mon
    return nil unless ev && mon && !ev.transparent
    {'s'=>mon.species.to_s,'sh'=>!!mon.shiny?,'m'=>ev.map.map_id,
     'x'=>ev.x,'y'=>ev.y,'d'=>ev.direction,'p'=>ev.pattern,'v'=>ev.move_speed.clamp(1,8)}
  end
  def self.receive(_name,key,data,from=nil)
    session_changed
    return unless @session && key=='follow' && data.is_a?(Hash) && data['v']==1 &&
      data['e'].is_a?(String) && data['e'].match?(/\A[0-9a-f]{12}\z/) &&
      data['n'].is_a?(Integer) && data['n'].between?(1,2**53)
    sender=from || (@session.peers.first && @session.peers.first[0])
    return unless @session.peers.any? { |p| p[0]==sender }
    old=@peers[sender]
    return if old && old['e']==data['e'] && old['n']>=data['n']
    f=data['f']
    # Other maps are valid advertisements too: retaining them lets us draw
    # immediately on a map change, and retire the previous map's copy.
    return unless f.nil? || (f.is_a?(Hash) && f['m'].is_a?(Integer) &&
      f['m'].between?(1,100_000) && f['x'].is_a?(Integer) && f['y'].is_a?(Integer) &&
      f['x'].between?(0,100_000) && f['y'].between?(0,100_000) &&
      [2,4,6,8].include?(f['d']) && [0,1,2,3].include?(f['p']) &&
      f['v'].is_a?(Numeric) && f['v'].between?(1,8) && [true,false].include?(f['sh']) &&
      KIF::Coop::Mon.sym(f['s'],GameData::Species))
    @peers[sender]={'e'=>data['e'],'n'=>data['n'],'f'=>f}
  end
  def self.position(ev,x,y,d)
    unless ev.moving?
      dx=x-ev.x; dy=y-ev.y
      if dx.abs+dy.abs==1
        ev.move_generic(dx>0 ? 6 : dx<0 ? 4 : dy>0 ? 2 : 8)
      elsif dx!=0 || dy!=0
        ev.moveto(x,y)
      end
    end
    ev.direction=d
  end
  def self.frame
    session_changed
    return unless @session
    members=@session.peers.map(&:first)
    @peers.delete_if { |slot,_| !members.include?(slot) }
    if $PokemonTemp && $game_map && now-@last_send>=0.2
      f=snapshot
      if f!=@sent || now-@last_send>=2
        data={'v'=>1,'e'=>@nonce,'n'=>@serial+1,'f'=>f}
        if KIF::Net.share(ID,'follow',data)
          @serial+=1; @sent=f; @last_send=now
        end
      end
    end
    if $scene.is_a?(Scene_Map) && $game_map && $MapFactory && !($game_temp && $game_temp.in_battle)
      update_followers
    else
      dispose_followers
    end
  rescue StandardError => e
    KIF::Net.log("Modern Party followers: #{e.class}: #{e.message}")
  end
  # Visual peers live only in this module, never in saved dependent events,
  # collision tables, the player's party, or native encounter lists.
  class FollowerGhost < Game_Character
    def active?; false; end
    def name; ''; end
    def update_command; end
  end
  class FollowerSprite < Sprite
    def initialize(viewport,character)
      super(viewport)
      @character=character
    end
    def update
      super
      g=@character
      if @graphic!=g.character_name
        @sheet.dispose if @sheet
        @graphic=g.character_name
        @sheet=AnimatedBitmap.new('Graphics/Characters/'+@graphic)
      end
      @sheet.update
      self.bitmap=@sheet.bitmap
      cw=bitmap.width/4; ch=bitmap.height/4
      g.sprite_size=[cw,ch]
      self.src_rect.set(g.pattern*cw,(g.direction-2)/2*ch,cw,ch)
      self.ox=cw/2; self.oy=ch-g.bob_height
      self.x=g.screen_x; self.y=g.screen_y; self.z=g.screen_z(ch)
      self.visible=!g.transparent; self.opacity=g.opacity
      self.zoom_x=self.zoom_y=defined?(KIF::MapZoom) ? KIF::MapZoom.scale : 1.0
      pbDayNightTint(self)
    end
    def dispose
      self.bitmap=nil
      @sheet.dispose if @sheet
      @sheet=nil
      super
    end
KIF::Net.on_share(KIFModernFollowerNet::ID) { |name,key,data,from=nil| KIFModernFollowerNet.receive(name,key,data,from) }
Graphics.singleton_class.prepend(Module.new do
  def update(*args)
    super
    KIFModernFollowerNet.frame
  end
end)
  end
  def self.dispose_followers
    @remotes.each_value do |row|
      sprite=row[:sprite]
      sprite.dispose if sprite && !sprite.disposed?
    end
    @remotes.clear
  end
  def self.valid_follower?(d)
    d.is_a?(Hash) && d['m'].is_a?(Integer) && !!follower_map(d['m']) &&
      d['x'].is_a?(Integer) && d['y'].is_a?(Integer) && follower_map(d['m']).valid?(d['x'],d['y']) &&
      [2,4,6,8].include?(d['d']) && [0,1,2,3].include?(d['p']) &&
      d['v'].is_a?(Numeric) && d['v'].between?(1,8) && [true,false].include?(d['sh']) &&
      !!KIF::Coop::Mon.sym(d['s'],GameData::Species)
  end
  def self.update_followers
    live=[]
    @peers.each do |slot,peer|
      d=peer['f']; next unless valid_follower?(d)
      source_map=$MapFactory.getMapNoAdd(d['m'])
      next unless source_map
      data=GameData::Species.get(KIF::Coop::Mon.sym(d['s'],GameData::Species))
      graphic=getRoamingSprite(data,d['sh'])
      next if !graphic || graphic.empty? || !pbResolveBitmap('Graphics/Characters/'+graphic)
      live << slot
      row=@remotes[slot]
      unless row && row[:map].equal?($game_map) && row[:event].map.equal?(source_map) && !row[:sprite].disposed? &&
          row[:sprite].viewport.equal?(Spriteset_Map.viewport) && !row[:sprite].viewport.disposed?
        old=@remotes.delete(slot)
        old[:sprite].dispose if old && !old[:sprite].disposed?
        ev=FollowerGhost.new(source_map)
        ev.through=true; ev.step_anime=true; ev.moveto(d['x'],d['y'])
        row=@remotes[slot]={map:$game_map,event:ev,sprite:FollowerSprite.new(Spriteset_Map.viewport,ev)}
      end
      ev=row[:event]
      ev.character_name=graphic; ev.move_speed=d['v']
      position(ev,d['x'],d['y'],d['d'])
      ev.update; ev.pattern=d['p']; row[:sprite].update
    end
    (@remotes.keys-live).each do |slot|
      row=@remotes.delete(slot); row[:sprite].dispose unless row[:sprite].disposed?
    end
  end
end

end

# The existing world authority continues to own auto-battle reservations.
if defined?(HoennMultiplayer::Room) && defined?(KIF::Net::ModShare)
KIFModernFieldBattle.singleton_class.prepend(Module.new do
  def acquire_target
    result=super
    return result unless result && HoennMultiplayer.active?
    ev=@state[:target]
    # The local reservation was set by super; the authority checks its own
    # event. Temporarily release it for the same-process authority request.
    ev.instance_variable_set(:@kmp_field_reserved,false)
    req=HoennMultiplayer.take(ev,'auto')
    ev.instance_variable_set(:@kmp_field_reserved,true)
    if req
      @state[:phase]=:net_wait; @state[:age]=0
      true
    else
      clear_deployment
      false
    end
  end
  def eligible?(ev)
    super && (!HoennMultiplayer.active? ||
      (!ev.instance_variable_get(:@hmp_busy) && !HoennMultiplayer.claimed?(ev)))
  end
  def resolve
    super
    HoennMultiplayer.finish(!!@last_result[:won]) if HoennMultiplayer.active? && @last_result
  end
  def clear_deployment
    HoennMultiplayer.finish if HoennMultiplayer.active?
    super
  end
  def begin_return
    HoennMultiplayer.finish if HoennMultiplayer.active?
    super
  end
end)

end
