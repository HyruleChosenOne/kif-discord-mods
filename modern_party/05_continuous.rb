module KIFModernContinuous
  def active?; !!@session; end
  def command
    return begin_return if @session
    return false unless safe? && $PokemonSystem.kmp_field_battles==1 && follower && mon && mon.able?
    return false if mon.hp*3<=mon.totalhp
    @session={map:$game_map,pokemon:mon,follower:follower,avoided:[]}
    begin_return unless acquire_target
    true
  end
  def cancel
    clear_deployment
    @session=nil
    true
  end
  def begin_return
    return false unless @session
    actor=@session[:follower]
    @state ||= {follower:actor,pokemon:@session[:pokemon],map:@session[:map],
      target:nil,old_through:actor.through,old_opacity:nil}
    target=@state[:target]
    if target
      target.instance_variable_set(:@kmp_field_reserved,false)
      target.opacity=@state[:old_opacity]
    end
    @session[:retreating]=true
    @state[:phase]=:return;@state[:age]=0
    true
  end
  def clear_deployment
    if @state
      if @state[:target]
        @state[:target].instance_variable_set(:@kmp_field_reserved,false)
        @state[:target].opacity=@state[:old_opacity]
      end
      @state[:follower].through=@state[:old_through]
    end
    @state=nil
  end
  def session_safe?
    safe? && $PokemonSystem.kmp_field_battles==1 &&
      $game_map.equal?(@session[:map]) && mon.equal?(@session[:pokemon]) &&
      follower.equal?(@session[:follower]) && mon.able? &&
      (@session[:retreating] || mon.hp*3>mon.totalhp)
  end
  def acquire_target
    return false unless @session
    actor=@session[:follower]
    targets=$game_map.events.values.select do |event|
      eligible?(event) && !@session[:avoided].include?(event) &&
        (event.x-$game_player.x).abs+(event.y-$game_player.y).abs<=7
    end.sort_by { |event| (event.x-actor.x).abs+(event.y-actor.y).abs }
    target=targets.find { |event| path(actor,[event.x,event.y]) }
    return false unless target
    clear_deployment
    target.instance_variable_set(:@kmp_field_reserved,true)
    @state={follower:actor,pokemon:mon,target:target,map:$game_map,phase: :approach,
      age:0,old_through:actor.through,old_opacity:target.opacity}
    actor.through=false
    true
  end
  def tick
    if @hud && !@hud.disposed?
      safe? ? @hud.update : @hud.dispose
    end
    return cancel if @session && !session_safe?
    command if safe? && triggered?
    return unless @session
    s=@state;return unless s
    actor=s[:follower];target=s[:target]
    if s[:phase]!=:return && !eligible_reserved?(target)
      @session[:avoided]<<target
      begin_return unless acquire_target
      return
    end
    s[:age]+=1
    if s[:age]>360
      if @session[:retreating]
        cancel
        KIFModernFollower.follow($PokemonTemp.dependentEvents,$game_player,actor,true)
      else
        @session[:avoided]<<target
        begin_return unless acquire_target
      end
      return
    end
    case s[:phase]
    when :approach
      return if actor.moving?
      steps=path(actor,[target.x,target.y])
      unless steps
        @session[:avoided]<<target
        begin_return unless acquire_target
        return
      end
      if steps.empty?
        s[:phase]=:fight;s[:age]=0
      else
        step_actor(actor,steps.first)
      end
    when :fight
      pbSEPlay(hit_sound(s[:pokemon],target.pokemon)) if s[:age]==18
      target.opacity=150+(Math.sin(s[:age]*0.7)*80).round
      if s[:age]>=36
        target.opacity=s[:old_opacity]
        resolve
        if !@last_result[:won] || mon.hp*3<=mon.totalhp
          begin_return
        end
        return cancel unless session_safe?
        begin_return unless @session[:retreating] || acquire_target
      end
    when :return
      return if actor.moving?
      steps=path(actor,[$game_player.x,$game_player.y],12)
      if !steps
        cancel
        KIFModernFollower.follow($PokemonTemp.dependentEvents,$game_player,actor,true)
      elsif steps.empty?
        cancel
      else
        step_actor(actor,steps.first)
      end
    end
  end
end
KIFModernFieldBattle.singleton_class.prepend(KIFModernContinuous)
