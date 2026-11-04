# Experimental field battles: only actual roaming actors and cosmetic followers.
KIF::Options.define(:kmp_field_battles,1,:save)
KIF::Options.add(:others,:save) do
  EnumOption.new('Follower auto-battle',['Off','On'],proc { $PokemonSystem.kmp_field_battles },
    proc { |v| $PokemonSystem.kmp_field_battles=v;KIFModernFieldBattle.cancel },
    'Experimental quick battles against nearby roaming Pokemon. Story companions never battle.')
end
module KIFModernFieldBattle
  DIRECTIONS={2=>[0,1],4=>[-1,0],6=>[1,0],8=>[0,-1]}
  class << self;attr_reader :state,:last_result;end
  def self.safe?
    return false unless $scene.is_a?(Scene_Map) && $game_temp && $Trainer && $game_map
    return false if $game_temp.in_menu || $game_temp.in_battle || $game_temp.message_window_showing || $game_temp.player_transferring
    return false if pbMapInterpreterRunning? || $game_player.move_route_forcing || $game_system.menu_disabled
    return false if $PokemonGlobal.surfing || $PokemonGlobal.diving || $PokemonGlobal.bicycle
    return false if pbInSafari? || pbInBugContest?
    $PokemonGlobal.dependentEvents.all? { |row| KIFModernFollower.ours?(row) }
  end
  def self.follower
    $PokemonTemp.dependentEvents.getEventByName(KIFModernFollower::NAME)
  end
  def self.mon
    KIFModernFollower.mon
  end
  def self.deployed?(event);@state && @state[:follower].equal?(event);end
  def self.eligible?(event)
    return false unless KIFModernParty.roaming_target?(event) && !event.moving? && !event.jumping?
    return false if event.pokemon.egg?
    return false if event.pokemon.shiny? || !event.pokemon.able?
    return false if event.instance_variable_get(:@kmp_field_reserved)
    true
  end
  def self.eligible_reserved?(event)
    return false unless $game_map.events[event.id].equal?(event)
    return false if event.instance_variable_get(:@erased) || event.pokemon.shiny? || !event.pokemon.able?
    return false if event.instance_variable_get(:@hno_radar_stationary) || event.instance_variable_get(:@kif_fusion_pending) || event.instance_variable_get(:@hno_turf_busy)
    true
  end
  def self.path(character,goal,max=10)
    map=$game_map;origin=[character.x,character.y];queue=[[origin,[]]];seen={origin=>true}
    until queue.empty?
      tile,steps=queue.shift
      return steps if (tile[0]-goal[0]).abs+(tile[1]-goal[1]).abs<=1
      next if steps.length>=max
      DIRECTIONS.each do |direction,(dx,dy)|
        nx=tile[0]+dx;ny=tile[1]+dy;key=[nx,ny]
        next if seen[key] || !map.valid?(nx,ny)
        next unless map.passable?(tile[0],tile[1],direction,character) && map.passable?(nx,ny,10-direction,character)
        next if map.events.values.any? { |e| !e.through && e.at_coordinate?(nx,ny) }
        seen[key]=true;queue<<[key,steps+[direction]]
      end
    end
    nil
  end
  def self.command
    return cancel if @state
    return false unless safe? && $PokemonSystem.kmp_field_battles==1 && mon && mon.able? && follower
    return false if mon.hp*3<=mon.totalhp
    dx,dy=DIRECTIONS[$game_player.direction]
    targets=$game_map.events.values.select do |e|
      next false unless eligible?(e)
      x=e.x-$game_player.x;y=e.y-$game_player.y
      x*dx+y*dy>0 && x.abs+y.abs<=7
    end.sort_by { |e| (e.x-$game_player.x).abs+(e.y-$game_player.y).abs }
    target=targets.find { |e| path(follower,[e.x,e.y]) }
    return false unless target
    target.instance_variable_set(:@kmp_field_reserved,true)
    @state={follower:follower,pokemon:mon,target:target,map:$game_map,phase: :approach,age:0,old_through:follower.through,old_opacity:target.opacity}
    follower.through=false
    true
  end
  def self.cancel
    if @state
      @state[:target].instance_variable_set(:@kmp_field_reserved,false)
      @state[:target].opacity=@state[:old_opacity]
      @state[:follower].through=@state[:old_through]
    end
    @state=nil
    true
  end
  def self.type_score(a,b)
    a.types.map { |type| Effectiveness.calculate(type,*b.types)/Effectiveness::NORMAL_EFFECTIVE.to_f }.max
  end
  def self.hit_sound(attacker,target)
    matchup=type_score(attacker,target)
    matchup>1 ? 'Battle damage super' : matchup<1 ? 'Battle damage weak' : 'Battle damage normal'
  end
  def self.step_actor(actor,direction)
    dx,dy=DIRECTIONS[direction]
    old=actor.through
    crossing=actor.at_coordinate?($game_player.x,$game_player.y) ||
      [actor.x+dx,actor.y+dy]==[$game_player.x,$game_player.y]
    actor.through=true if crossing
    actor.move_generic(direction)
  ensure
    actor.through=old
  end
  def self.resolve
    return unless @state && @state[:phase]==:fight && !@state[:rewarded]
    @state[:rewarded]=true
    s=@state;hero=s[:pokemon];foe=s[:target].pokemon
    simulation=KIFModernAutoCombat.simulate(hero,foe)
    won=simulation[:won]
    damage=simulation[:damage]
    hero.hp=[hero.hp-damage,1].max # Retreat instead of fainting in a quick battle.
    if won
      foe_copy=foe.clone
      s[:target].despawn # Claim once before awarding; no capture, EVs or drops.
      rows=$Trainer.party.select { |p| KIFModernParty.exp_recipient?(p,p.equal?(hero)) }.map do |p|
        amount=KIFModernParty.reward(p,foe_copy,p.equal?(hero),true)
        cap=KIF::LevelCap.cap_for(p)
        if cap
          room=KIF::LevelCap.room(p)
          p.kif_banked_exp=p.kif_banked_exp.to_i+[amount-room,0].max if KIF::LevelCap.behavior==0
          # Field rewards never bypass a selected cap; RC conversion uses the
          # same level crossings as battle rewards, with native bag overflow.
          if KIF::LevelCap.behavior==2
            total=p.growth_rate.add_exp(p.exp,amount)
            candies=[p.growth_rate.level_from_exp(total)-[p.level,cap].max,0].max
            candies.times do
              unless $PokemonBag.pbCanStore?(:RARECANDY,1) && $PokemonBag.pbStoreItem(:RARECANDY,1)
                $PokemonGlobal.pcItemStorage||=PCItemStorage.new
                $PokemonGlobal.pcItemStorage.pbStoreItem(:RARECANDY,1)
              end
            end
          end
          amount=[amount,room].min
        elsif $PokemonSystem.level_caps==1 && pokemonExceedsLevelCap(p)
          amount=0
        end
        KIFModernParty.award(p,amount)
      end.compact
      @hud.dispose if @hud && !@hud.disposed?
      unless rows.empty?
        @hud=KIFModernExpHUD.new(rows)
        # Leave the centered arrival title clear; six cards still end above
        # the automatic move notice at the bottom of the field screen.
        @hud.cards.each { |card| card.y+=44 }
      end
    end
    @last_result={won:won,species:foe.species,damage:damage,simulation:simulation}
    s[:target].instance_variable_set(:@kmp_field_reserved,false) if won
    s[:phase]=:return;s[:age]=0
  end
  def self.triggered?
    keyboard=KIFModernInput.key_triggered?(:LALT)
    axis=KIFModernInput.controller_value(:axes_trigger,1).to_f
    down=axis>0.5;edge=down && !@trigger_down;@trigger_down=down
    keyboard || edge
  end
  def self.tick
    if @hud && !@hud.disposed?
      safe? ? @hud.update : @hud.dispose
    end
    return cancel if @state && (!follower.equal?(@state[:follower]) || !safe? || !@state[:map].equal?($game_map) || !mon.equal?(@state[:pokemon]) || $PokemonSystem.kmp_field_battles!=1)
    command if safe? && triggered?
    s=@state;return unless s
    return cancel if s[:phase]!=:return && !eligible_reserved?(s[:target])
    s[:age]+=1
    return cancel if s[:age]>360
    actor=s[:follower];target=s[:target]
    case s[:phase]
    when :approach
      return cancel unless $game_map.events[target.id].equal?(target)
      return if actor.moving?
      steps=path(actor,[target.x,target.y]);return cancel unless steps
      if steps.empty?
        s[:phase]=:fight;s[:age]=0
      else
        step_actor(actor,steps.first)
      end
    when :fight
      return cancel unless $game_map.events[target.id].equal?(target)
      pbSEPlay(hit_sound(s[:pokemon],target.pokemon)) if s[:age]==18
      target.opacity=150+(Math.sin(s[:age]*0.7)*80).round
      if s[:age]>=36
        target.opacity=255;resolve
      end
    when :return
      return if actor.moving?
      steps=path(actor,[$game_player.x,$game_player.y],12)
      return cancel if !steps || steps.empty?
      step_actor(actor,steps.first)
    end
  end
end
DependentEvents.prepend(Module.new do
  def pbFollowEventAcrossMaps(leader,follower,*args)
    return if KIFModernFieldBattle.deployed?(follower)
    super
  end
end)
OverworldPokemonEvent.prepend(Module.new do
  def update
    return if instance_variable_get(:@kmp_field_reserved)
    super
  end
end)
Game_Event.prepend(Module.new do
  def start
    KIFModernFieldBattle.cancel if instance_variable_get(:@kmp_field_reserved)
    super
  end
end)
HoennNativeKIFTerritorial.singleton_class.prepend(Module.new do
  def valid?(event)
    !event.instance_variable_get(:@kmp_field_reserved) && super
  end
end) if defined?(HoennNativeKIFTerritorial)
HoennNativeKIFSocial.singleton_class.prepend(Module.new do
  def reason(event,frame)
    return :fighting if event.instance_variable_get(:@kmp_field_reserved)
    super
  end
end)
Events.onMapUpdate += proc { |_sender,_event| KIFModernFieldBattle.tick }
PokemonPauseMenu_Scene.prepend(Module.new do
  def pbStartScene(*args)
    KIFModernFieldBattle.cancel
    super
  end
end)
