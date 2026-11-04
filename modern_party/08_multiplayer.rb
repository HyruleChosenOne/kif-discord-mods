# Hoenn provides the shared-world protocol; Modern Party adds follower visuals
# and reservations for its auto attacks. No networking on older engines.
if defined?(HoennMultiplayer::Room) && defined?(KIF::Net::ModShare)
module HoennMultiplayer
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
  end
  def self.dispose_followers
    @remotes.each_value do |row|
      sprite=row[:sprite]
      sprite.dispose if sprite && !sprite.disposed?
    end
    @remotes.clear
  end
  def self.valid_follower?(d)
    d.is_a?(Hash) && d['m'].is_a?(Integer) && d['m']==$game_map.map_id &&
      d['x'].is_a?(Integer) && d['y'].is_a?(Integer) && $game_map.valid?(d['x'],d['y']) &&
      [2,4,6,8].include?(d['d']) && [0,1,2,3].include?(d['p']) &&
      d['v'].is_a?(Numeric) && d['v'].between?(1,6) && [true,false].include?(d['sh']) &&
      !!KIF::Coop::Mon.sym(d['s'],GameData::Species)
  end
  def self.update_followers
    live=[]
    @room.peers.each do |slot,peer|
      d=peer['f']; next unless valid_follower?(d)
      data=GameData::Species.get(KIF::Coop::Mon.sym(d['s'],GameData::Species))
      graphic=getRoamingSprite(data,d['sh'])
      next if !graphic || graphic.empty? || !pbResolveBitmap('Graphics/Characters/'+graphic)
      live << slot
      row=@remotes[slot]
      unless row && row[:map].equal?($game_map) && !row[:sprite].disposed? &&
          row[:sprite].viewport.equal?(Spriteset_Map.viewport) && !row[:sprite].viewport.disposed?
        old=@remotes.delete(slot)
        old[:sprite].dispose if old && !old[:sprite].disposed?
        ev=FollowerGhost.new($game_map)
        ev.through=true; ev.step_anime=true; ev.moveto(d['x'],d['y'])
        row=@remotes[slot]={map:$game_map,event:ev,sprite:FollowerSprite.new(Spriteset_Map.viewport,ev)}
      end
      ev=row[:event]
      ev.character_name=graphic; ev.move_speed=d['v']
      position(ev,d['x'],d['y'],d['d'])
      ev.pattern=d['p']; ev.update; row[:sprite].update
    end
    (@remotes.keys-live).each do |slot|
      row=@remotes.delete(slot); row[:sprite].dispose unless row[:sprite].disposed?
    end
  end
end

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
