module KIFModernFollower
  NAME='ModernPartyFollower'
  DELTAS={2=>[0,1],4=>[-1,0],6=>[1,0],8=>[0,-1]}
  class << self; attr_accessor :step_origin; end
  def self.rear_tile(leader,character=leader)
    old_through=character.through
    character.through=false
    ([10-leader.direction,4,6,2,8].uniq).each do |direction|
      tile=$MapFactory.getFacingTile(direction,leader)
      next unless tile && $MapFactory.isPassableStrict?(*tile,character)
      return tile
    end
    nil
  ensure
    character.through=old_through
  end
  def self.follow(deps,leader,follower,instant)
    return if defined?(KIFModernFieldBattle) && KIFModernFieldBattle.deployed?(follower)
    origin=step_origin
    tile=origin if !instant && origin && origin!=[leader.map.map_id,leader.x,leader.y]
    if !tile && !instant && follower.map.map_id==leader.map.map_id &&
       (follower.x-leader.x).abs+(follower.y-leader.y).abs==1
      return
    end
    tile ||= rear_tile(leader,follower)
    unless tile
      follower.transparent=true
      return
    end
    if follower.map.map_id!=tile[0]
      index=deps.pbEnsureEvent(follower,tile[0]);return if index<0
      follower=deps.realEvents[index]
      instant=true
    end
    follower.transparent=false
    follower.move_speed=leader.move_speed
    dx=tile[1]-follower.x;dy=tile[2]-follower.y
    if instant
      follower.moveto(tile[1],tile[2])
    elsif dx.abs+dy.abs==1
      direction=dx>0 ? 6 : dx<0 ? 4 : dy>0 ? 2 : 8
      follower.move_generic(direction)
    elsif dx!=0 || dy!=0
      pbFancyMoveTo(follower,tile[1],tile[2],leader)
    end
    follower.direction=leader.direction
  end
  def self.ours?(row); row && row[8]==NAME; end
  def self.mon
    $Trainer && $Trainer.party.find { |pokemon| pokemon && !pokemon.egg? && pokemon.able? }
  end
  def self.summoned?; $PokemonGlobal && $PokemonGlobal.instance_variable_get(:@kmp_follower_summoned)==true; end
  def self.toggle
    return false unless defined?(KIFModernFieldBattle) && KIFModernFieldBattle.safe?
    return false unless summoned? || (mon && mon.able?)
    KIFModernFieldBattle.cancel
    $PokemonGlobal.instance_variable_set(:@kmp_follower_summoned,!summoned?)
    refresh
    true
  end
  def self.triggered?
    keyboard=Input.triggerex?(:LCTRL)
    buttons=Input::Controller.connected? ? Input::Controller.raw_button_states : []
    value=buttons[10] # SDL right shoulder / Xbox RB (KIF::Keys::PAD_BUTTONS).
    down=value && value!=0
    edge=down && !@rb_down;@rb_down=down
    keyboard || edge
  end
  def self.tick
    pressed=triggered?
    toggle if pressed
    refresh if Graphics.frame_count%20==0 && $scene.is_a?(Scene_Map)
  end
  def self.refresh
    return unless $PokemonGlobal && $PokemonTemp && $game_map && $game_player && $MapFactory && $Trainer
    return if defined?(KIFModernFieldBattle) && KIFModernFieldBattle.state
    return if pbMapInterpreterRunning? || $game_player.move_route_forcing
    deps=$PokemonTemp.dependentEvents
    rows=$PokemonGlobal.dependentEvents
    blocked=$PokemonGlobal.surfing || $PokemonGlobal.diving || $PokemonGlobal.bicycle || rows.any? { |r| !ours?(r) }
    lead=mon
    graphic=lead && lead.able? ? getRoamingSprite(lead.species_data,lead.shiny?) : nil
    if blocked || !graphic || graphic.empty? || !summoned?
      deps.removeEventByName(NAME)
      return
    end
    unless rows.any? { |row| ours?(row) }
      tile=rear_tile($game_player)
      return unless tile
      data=[-1,987654,tile[0],tile[1],tile[2],$game_player.direction,graphic,0,NAME,nil]
      deps.kmp_add_follower(data)
    end
    deps.eachEvent do |event,data|
      next unless ours?(data)
      event.character_name=graphic;data[6]=graphic;event.through=true
      if event.map.map_id==$game_map.map_id && event.at_coordinate?($game_player.x,$game_player.y) && !event.moving? && !$game_player.moving?
        follow(deps,$game_player,event,true)
        data[2]=event.map.map_id;data[3]=event.x;data[4]=event.y
      end
    end
  end
end
DependentEvents.prepend(Module.new do
  def pbFollowEventAcrossMaps(leader,follower,instant=false,leaderIsTrueLeader=true)
    if follower && $PokemonGlobal.dependentEvents.any? { |row| KIFModernFollower.ours?(row) && row[0]==follower.map_id && row[1]==follower.id }
      return KIFModernFollower.follow(self,leader,follower,instant)
    end
    super
  end
  def kmp_add_follower(data)
    event=createEvent(data)
    $PokemonGlobal.dependentEvents << data
    @realEvents << event
    @lastUpdate+=1
  end
end)
Game_Player.prepend(Module.new do
  def move_generic(*args)
    old=KIFModernFollower.step_origin
    KIFModernFollower.step_origin=[map.map_id,x,y]
    super
  ensure
    KIFModernFollower.step_origin=old
  end
  def jump(*args)
    old=KIFModernFollower.step_origin
    KIFModernFollower.step_origin=[map.map_id,x,y]
    super
  ensure
    KIFModernFollower.step_origin=old
  end
end)
Events.onMapUpdate += proc { |_sender,_event| KIFModernFollower.tick }
Game.singleton_class.prepend(Module.new do
  def save(*args,**kwargs,&block)
    KIFModernFieldBattle.cancel if defined?(KIFModernFieldBattle)
    super
  end
  def load(*args,&block)
    KIFModernFieldBattle.cancel if defined?(KIFModernFieldBattle)
    super
  end
end)
