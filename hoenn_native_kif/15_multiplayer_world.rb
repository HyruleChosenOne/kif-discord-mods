# KIF 2.0 networking is optional on older supported engines.
if defined?(KIF::Net::ModShare) && defined?(KIF::Coop::Mon)
module HoennMultiplayer
  class << self; attr_reader :room; end
  @out=[]; @jobs=[]; @remotes={}; @replicas={}; @descriptors={}; @versions={}
  @counter=0; @last_send=-10; @last_world=-10; @last_ask=-10
  @codec=KIF::Coop::Mon
  def self.cancel_field; KIFModernFieldBattle.cancel if defined?(KIFModernFieldBattle); end
  def self.return_field; KIFModernFieldBattle.begin_return if defined?(KIFModernFieldBattle); end
  def self.field_state; KIFModernFieldBattle.state if defined?(KIFModernFieldBattle); end
  def self.field_active?; defined?(KIFModernFieldBattle) && KIFModernFieldBattle.active?; end
  def self.update_followers; end
  def self.dispose_followers; end
  def self.now; KIF::Net.now; end
  def self.active?; !!@room && KIF::Net.connected?; end
  def self.owner?; !active? || @room.authority?; end
  def self.ours?(ev)
    HoennNativeKIFSocial.event_ours?(ev) && !ev.instance_variable_get(:@hno_radar_stationary)
  end
  def self.events
    return [] unless $game_map
    $game_map.events.values.select { |ev| ours?(ev) }.first(LIMIT)
  end
  def self.uid(ev)
    return nil unless ev && ours?(ev)
    id=ev.instance_variable_get(:@hmp_uid)
    unless id
      @counter+=1; id="#{@room.epoch}-w#{@counter}"
      ev.instance_variable_set(:@hmp_uid,id)
    end
    id
  end
  def self.find(id); events.find { |ev| ev.instance_variable_get(:@hmp_uid)==id }; end
  def self.claimed?(ev)
    active? && ev && @room.claims.key?(ev.instance_variable_get(:@hmp_uid))
  end
  def self.frozen?(ev)
    active? && ours?(ev) && (!owner? || claimed?(ev))
  end
  def self.send_packet(key,d,to=nil)
    # Prefer the newest positions, and leave room for reservation completion.
    if %w[hello world mon].include?(key)
      @out.delete_if { |k,old,target| k==key && target==to && (key!='mon' || old['u']==d['u']) }
    end
    critical=%w[take grant done].include?(key)
    if @out.length>=64
      index=@out.index { |k,_,_| !%w[take grant done].include?(k) }
      return false unless critical && index
      @out.delete_at(index)
    end
    index=critical && @out.index { |k,_,_| !%w[take grant done].include?(k) }
    index ? @out.insert(index,[key,d,to]) : @out.push([key,d,to])
    true
  end
  def self.flush
    8.times do
      item=@out.first; break unless item
      key,d,to=item
      # A pending packet from another map/authority is no longer meaningful.
      if d['m']!=@room.map || (key!='hello' && d['e']!=@room.term) || (to && !@room.members.include?(to))
        @out.shift; next
      end
      target=KIF::Net.session.peers.length<=1 ? nil : to
      break unless KIF::Net.share(ID,key,d,to:target)
      @out.shift
    end
  end
  def self.make_room(session)
    nonce=KIF::Net::Crypto.random(6).unpack1('H*')
    @room=Room.new(session.my_slot,nonce)
    @room.emit=method(:send_packet)
    @room.available=proc do |id,revision|
      ev=find(id)
      ev && revision==version(ev) && !ev.instance_variable_get(:@kmp_field_reserved) &&
        !ev.instance_variable_get(:@hno_turf_busy) && !ev.instance_variable_get(:@kif_fusion_pending)
    end
    @room.removed=proc { |id| ev=find(id); ev.despawn if ev }
    @room.grant=proc { |req,id,kind| @jobs << [req,id,kind] }
    @room.packet=method(:receive_world)
    @session=session; @context=nil
  end
  def self.receive(_name,key,d,from=nil)
    s=KIF::Net.session
    return unless s && s.connected? && @room && @session.equal?(s)
    # KIF's two-player handler omits the slot. Its authenticated peer is known.
    from ||= s.peers.first && s.peers.first[0]
    return unless from
    @room.receive(key,d,from)
  end
  def self.follower_data
    return nil unless defined?(KIFModernFollower)
    ev=KIFModernFieldBattle.follower; mon=KIFModernFollower.mon
    return nil unless ev && mon && !ev.transparent
    {'s'=>mon.species.to_s,'sh'=>mon.shiny?,'m'=>ev.map.map_id,
     'x'=>ev.x,'y'=>ev.y,'d'=>ev.direction,'p'=>ev.pattern,'v'=>ev.move_speed}
  end
  def self.heartbeat
    @room.hello(follower_data)
  end
  FLAGS=%w[alpha head_alpha body_alpha natural_shiny head_shiny body_shiny glitter].freeze
  def self.dump_mon(mon)
    data=@codec.dump(mon,true)
    data['hmp']=FLAGS.map { |name| mon.instance_variable_get("@#{name}")==true }
    data
  end
  def self.version(ev)
    id=uid(ev); json=KIF::Net::Wire.json(dump_mon(ev.pokemon))
    old=@versions[id]
    @versions[id]=[json,old ? old[1]+1 : 1] unless old && old[0]==json
    @versions[id][1]
  end
  def self.world
    rows=events.map do |ev|
      id=uid(ev)
      [id,ev.x,ev.y,ev.direction,(@room.claims[id] || [-1])[0],version(ev)]
    end
    ids=rows.map(&:first)
    @versions.delete_if { |id,_| !ids.include?(id) }
    @room.say('world',{'rows'=>rows})
  end
  def self.describe(id,to)
    ev=find(id); return unless ev && ev.pokemon
    @room.say('mon',{'u'=>id,'p'=>dump_mon(ev.pokemon),'z'=>version(ev),
      't'=>ev.instance_variable_get(:@terrain).to_s},to)
  end
  def self.receive_world(key,d,from)
    case key
    when 'world'
      return if owner?
      rows=d['rows']
      return unless rows.is_a?(Array) && rows.length<=LIMIT && rows.all? { |r| valid_row?(r) }
      @latest=rows; @received_at=now
      # Applying events/sprites and starting battles is deferred to the map frame.
    when 'mon'
      return if owner? || !@room.token?(d['u']) || !%w[Land Cave Water].include?(d['t'])
      return unless @latest && @latest.any? { |r| r[0]==d['u'] }
      return unless d['z'].is_a?(Integer) && d['z'].between?(1,2**53)
      mon=@codec.load(d['p'],true)
      if mon && !mon.egg? && mon.able?
        flags=d['p']['hmp']
        if flags.is_a?(Array) && flags.length==FLAGS.length && flags.all? { |v| v==true || v==false }
          FLAGS.each_with_index { |name,i| mon.instance_variable_set("@#{name}",flags[i]) }
        end
        # The authority's no-item result is final too; assigning the replica
        # must not run the local held-item fallback again.
        mon.instance_variable_set(:@hno_wild_item_rolled,true)
        @descriptors[d['u']]=[mon,d['t'],d['z']]
      end
    end
  end
  def self.valid_row?(r)
    r.is_a?(Array) && r.length==6 && @room.token?(r[0]) &&
      r[1].is_a?(Integer) && r[2].is_a?(Integer) && $game_map.valid?(r[1],r[2]) &&
      [2,4,6,8].include?(r[3]) && [-1,0,1,2].include?(r[4]) &&
      r[5].is_a?(Integer) && r[5].between?(1,2**53)
  end
  def self.replica(row,mon,terrain)
    ev=$PokemonTemp.createTempEvent(TEMPLATE_EVENT_OW_POKEMON_NORMAL,$game_map.map_id,
      [row[1],row[2]],row[3],DynamicOverworldPokemonEvent) do |event|
      # Initialize native AI bookkeeping once; replace its random roll with the
      # checked owner's actual creature before it can update or be encountered.
      event.setup_pokemon(mon.species,mon.level,terrain.to_sym,:still,:still)
      event.pokemon=mon; event.species=mon.species; event.level=mon.level
      event.initialize_sprite(terrain.to_sym,mon.species_data)
      event.set_swimming if terrain=='Water'
      event.set_roaming_sprite
      event.instance_variable_set(:@hmp_uid,row[0])
    end
    @replicas[row[0]]=ev if ev
    ev
  end
  def self.position(ev,x,y,d)
    unless ev.moving?
      dx=x-ev.x; dy=y-ev.y
      if dx.abs+dy.abs==1
        through=ev.through; ev.through=true
        ev.move_generic(dx>0 ? 6 : dx<0 ? 4 : dy>0 ? 2 : 8)
        ev.through=through
      elsif dx!=0 || dy!=0
        ev.moveto(x,y)
      end
    end
    ev.direction=d
  end
  def self.paused_replica?(ev)
    return false unless active? && !owner? && $game_temp && $game_temp.in_menu && !$game_temp.in_battle
    @replicas[ev.instance_variable_get(:@hmp_uid)].equal?(ev) && ours?(ev)
  end
  def self.animate_paused_replica(ev)
    # Game_Character#update suppresses movement whenever in_menu is true.
    # Advance only the authoritative replica's pixels/animation, never its
    # movement commands, AI, encounter checks or step-event callbacks.
    frame=Graphics.frame_count
    return if ev.instance_variable_get(:@hmp_pause_visual_frame)==frame
    ev.instance_variable_set(:@hmp_pause_visual_frame,frame)
    moving=ev.moving?
    ev.instance_variable_set(:@moved_last_frame,ev.instance_variable_get(:@moved_this_frame))
    ev.instance_variable_set(:@moved_this_frame,moving)
    if moving
      speed=ev.move_speed_real
      {:@real_x=>ev.x*Game_Map::REAL_RES_X, :@real_y=>ev.y*Game_Map::REAL_RES_Y}.each do |ivar,target|
        value=ev.instance_variable_get(ivar)
        delta=target-value
        ev.instance_variable_set(ivar,delta.abs<=speed ? target : value+(delta>0 ? speed : -speed))
      end
      ev.calculate_bush_depth
    end
    if ev.step_anime || (moving && ev.walk_anime)
      ev.instance_variable_set(:@anime_count,ev.instance_variable_get(:@anime_count).to_f+1)
    end
    ev.update_pattern
  end
  def self.apply_world
    return if owner? || !@latest
    ids=@latest.map(&:first)
    @replicas.keys.each do |id|
      next if ids.include?(id) || @request && @request[:uid]==id
      ev=@replicas.delete(id); ev.despawn if ev && $game_map.events[ev.id].equal?(ev)
      @descriptors.delete(id)
    end
    @latest.each do |row|
      id,x,y,d,who,revision=row
      next if @request && @request[:uid]==id
      desc=@descriptors[id]
      desc=nil if desc && desc[2]!=revision
      ev=@replicas[id]
      ev=nil unless ev && $game_map.events[ev.id].equal?(ev)
      ev ||= replica(row,desc[0],desc[1]) if desc
      next unless ev
      # Descriptor refreshes preserve identity but update fusion/evolution/HP.
      if desc && !ev.pokemon.equal?(desc[0])
        ev.pokemon=desc[0]; ev.species=desc[0].species; ev.level=desc[0].level
        ev.initialize_sprite(desc[1].to_sym,desc[0].species_data); ev.set_roaming_sprite
      end
      ev.instance_variable_set(:@hmp_busy,who>=0)
      ev.instance_variable_set(:@hmp_revision,revision) if desc
      position(ev,x,y,d)
    end
    if now-@last_ask>=1.5
      # Only fetch new/changed creatures. Re-sending every full Pokemon at
      # every position update would exceed KIF's shared mod bandwidth.
      @latest.each do |row|
        desc=@descriptors[row[0]]
        @room.say('need',{'u'=>row[0]},@room.leader) unless desc && desc[2]==row[5]
      end
      @last_ask=now
    end
  end
  def self.take(ev,kind)
    return nil unless active? && ours?(ev)
    return nil if @request || ev.instance_variable_get(:@hmp_busy)
    id=uid(ev)
    @request={uid:id,event:ev,kind:kind,at:now,granted:false}
    revision=owner? ? version(ev) : ev.instance_variable_get(:@hmp_revision)
    req=@room.request(id,kind,revision)
    @request[:req]=req if @request
    @request=nil unless req
    req
  end
  def self.finish(consume=false)
    r=@request; @request=nil
    @room.finish(r[:req],consume) if r && @room && r[:req]
  end
  def self.battle(ev,method)
    return yield unless active? && ours?(ev)
    return yield if @executing.equal?(ev)
    return if @request || ev.instance_variable_get(:@hmp_busy)
    @battle_method=method
    take(ev,'battle')
    nil
  end
  def self.run_jobs
    jobs=@jobs; @jobs=[]
    jobs.each do |req,id,kind|
      r=@request
      next unless r && r[:req]==req && r[:uid]==id
      if kind=='denied'
        @request=nil
        if field_state && field_state[:phase]==:net_wait
          return_field
        end
        next
      end
      r[:granted]=true
      if kind=='auto'
        state=field_state
        if state && state[:target].equal?(r[:event]) && state[:phase]==:net_wait
          state[:phase]=:approach; state[:age]=0
        else
          finish
        end
      else
        ev=r[:event]
        begin
          @executing=ev
          ev.public_send(@battle_method || :start) if $game_map.events[ev.id].equal?(ev)
        ensure
          @executing=nil
          finish(true)
        end
      end
    end
    if @request && !@request[:granted] && now-@request[:at]>8
      finish
      return_field if field_active?
    end
  end
  def self.reset_map
    cancel_field
    finish
    @replicas.each_value { |ev| ev.despawn if $game_map && $game_map.events[ev.id].equal?(ev) }
    @replicas={}; @descriptors={}; @versions={}; @latest=nil; @jobs=[]; @out=[]
    @last_world=@last_send=@last_ask=-10
  end
  def self.frame
    s=KIF::Net.session
    unless s && s.connected?
      if @room
        reset_map; @room=nil; @context=nil; @session=nil
        dispose_followers
      end
      return
    end
    return unless $game_map && $scene.is_a?(Scene_Map)
    unless @session.equal?(s) && @room
      reset_map if @room
      make_room(s)
    end
    @room.members=s.peers.map(&:first)
    @room.prune
    @room.enter($game_map.map_id)
    context=[$game_map.object_id,@room.leader,@room.term]
    if @context!=context
      reset_map
      @room.reset_claims
      # Retire the former population when adopting another player's map.
      events.each(&:despawn) unless @room.authority?
      @context=context
    end
    if now-@last_send>=0.5
      send_packet('hello',heartbeat)
      @last_send=now
    end
    if owner? && now-@last_world>=0.5
      world
      @last_world=now
    end
    apply_world
    update_followers
    flush
    run_jobs
  rescue StandardError => e
    KIF::Net.log("Hoenn multiplayer: #{e.class}: #{e.message}")
  end
end

# Register once. Requests for descriptors go only to that map's authority.
KIF::Net.on_share(HoennMultiplayer::ID) do |name,key,data,from=nil|
  h=HoennMultiplayer; room=h.room
  if key=='need' && room && room.authority? && data.is_a?(Hash) &&
      data['v']==HoennMultiplayer::PROTOCOL && data['m']==room.map && data['e']==room.term
    s=KIF::Net.session; sender=from || (s.peers.first && s.peers.first[0])
    if room.members.include?(sender) && room.peers[sender] && room.peers[sender]['m']==room.map && room.token?(data['u'])
      h.describe(data['u'],sender)
    end
  else
    h.receive(name,key,data,from)
  end
end

HoennNativeKIF.singleton_class.prepend(Module.new do
  def tick; super if HoennMultiplayer.owner?; end
end)
[HoennNativeKIFSocial,HoennNativeKIFTerritorial].each do |mod|
  mod.singleton_class.prepend(Module.new do
    def tick; super if HoennMultiplayer.owner?; end
  end)
end
HoennNativeKIFTerritorial.singleton_class.prepend(Module.new do
  def valid?(ev); super && !HoennMultiplayer.claimed?(ev); end
end)
HoennNativeKIFSocial.singleton_class.prepend(Module.new do
  def reason(ev,frame)
    return :fighting if HoennMultiplayer.claimed?(ev)
    super
  end
end)
Game_Event.prepend(Module.new do
  def start
    HoennMultiplayer.battle(self,:start) { super }
  end
end)
OverworldPokemonEvent.prepend(Module.new do
  def update
    if HoennMultiplayer.paused_replica?(self)
      HoennMultiplayer.animate_paused_replica(self)
    elsif HoennMultiplayer.frozen?(self)
      # Animate/interpolate native coordinates without running local AI,
      # encounters, despawn distance, social fusion or autonomous routes.
      Game_Character.instance_method(:update).bind(self).call
    else
      super
    end
  end
  def update_command; return if HoennMultiplayer.frozen?(self); super; end
  def overworldPokemonBattle(*args)
    HoennMultiplayer.battle(self,:overworldPokemonBattle) { super }
  end
end)
Events.onMapUpdate += proc { |_sender,_args| HoennMultiplayer.frame }

end
