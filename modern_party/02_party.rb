# Modern party progression. Exact imported identities stay in native data APIs.
module KIFModernParty
  BASE_EXP = JSON.parse(File.read(File.join(__dir__,'base-exp.json'))).each_with_object({}) { |(key,value),out| out[key.to_s]=value }
  class << self
    attr_accessor :sharing, :evolution_moves
  end
  def self.yield_for(data)
    if data.is_a?(GameData::FusedSpecies)
      return ((yield_for(data.head_pokemon)+yield_for(data.body_pokemon))/2.0).floor
    end
    BASE_EXP.fetch(data.id.to_s, data.base_exp)
  end
  def self.round_exp(n);(n.ceil-n==0.5) ? n.floor : n.round;end
  def self.reward(pokemon, foe, participated, auto=false)
    # Gen IX integer base division, scaled by each recipient's own level.
    divisor=participated ? 1 : 2
    base=(yield_for(foe.species_data)*foe.level/(5*divisor)).floor
    exp=(base*((2.0*foe.level+10)/(foe.level+pokemon.level+10))**2.5).floor+1
    outsider=pokemon.owner.id!=$Trainer.id
    if outsider
      foreign=pokemon.owner.language!=0 && pokemon.owner.language!=$Trainer.language
      exp=round_exp(exp*(foreign ? 6963.0/4096 : 1.5))
    end
    exp=round_exp(exp*1.5) if pokemon.hasItem?(:LUCKYEGG)
    exp=round_exp(exp*4915.0/4096) if pokemon.happiness>=220
    exp=round_exp(exp*4915.0/4096) if pokemon.check_evolution_on_level_up(false)
    auto ? [exp*KIFModernParty.field_exp_percent/100,1].max : exp
  end
  def self.unlock(pokemon,moves)
    fresh=Array(moves).uniq.select { |id| GameData::Move.exists?(id) && !pokemon.hasMove?(id) }
    pokemon.instance_variable_set(:@kmp_available_moves,(Array(pokemon.instance_variable_get(:@kmp_available_moves))+fresh).uniq)
    pokemon.instance_variable_set(:@kmp_unlocked_moves,(Array(pokemon.instance_variable_get(:@kmp_unlocked_moves))+fresh).uniq)
    fresh
  end
  def self.award(pokemon,amount)
    before=[pokemon.exp,pokemon.level,pokemon.exp_fraction]
    final=pokemon.growth_rate.add_exp(pokemon.exp,amount)
    gained=final-pokemon.exp
    return nil if gained<=0
    pokemon.exp=final
    if pokemon.isFusion?
      pokemon.exp_gained_since_fused=pokemon.exp_gained_since_fused.to_i+gained
    end
    pokemon.exp_gained_with_player=pokemon.exp_gained_with_player.to_i+gained
    return nil if pokemon.shadowPokemon?
    after=pokemon.level
    (before[1]+1).upto(after) { pokemon.changeHappiness('levelup') }
    pokemon.calc_stats
    moves=pokemon.getMoveList.select { |level,id| level>before[1] && level<=after }.map { |level,id| id }
    moves=unlock(pokemon,moves)
    {pokemon:pokemon,old_exp:before[0],old_level:before[1],old_fraction:before[2],exp:gained,moves:moves}
  end
  def self.show(rows,scene=nil)
    # A double KO still gets one card per Pokemon, with combined rewards.
    merged={}
    rows.compact.each do |row|
      if merged[row[:pokemon].object_id]
        old=merged[row[:pokemon].object_id];old[:exp]+=row[:exp];old[:moves]|=row[:moves]
      else
        merged[row[:pokemon].object_id]=row.dup
      end
    end
    rows=merged.values
    return if rows.empty?
    rows.each { |row| row[:battle]=!!scene }
    hud=KIFModernExpHUD.new(rows)
    until hud.disposed?
      hud.update
      if scene && scene.respond_to?(:pbUpdate)
        scene.pbUpdate # Native battle update already advances Graphics/Input.
      else
        Graphics.update;Input.update
      end
    end
  ensure
    hud.dispose if hud && !hud.disposed?
  end
end

# Expose the optional sharing override only during native EXP distribution.
PokemonBag.prepend(Module.new do
  def pbHasItem?(item,*args)
    return true if item==:EXPALL && KIFModernParty.sharing && KIFModernParty.always_share?
    super
  end
end)
PokeBattle_Battle.prepend(Module.new do
  def pbGainExp
    previous=KIFModernParty.sharing;KIFModernParty.sharing=true
    @kmp_exp_rows=[]
    result=super
    # All recipients animate together; native owner/EV/switch-out gates remain.
    KIFModernParty.show(@kmp_exp_rows,@scene)
    result
  ensure
    KIFModernParty.sharing=previous;@kmp_exp_rows=nil
  end
  def pbDisplayPaused(message,*args)
    return if KIFModernParty.sharing && message==_INTL('Your party Pokémon in waiting also got Exp. Points!')
    super
  end
  def pbGainExpOne(index,foe,num,shares,all,messages=true)
    mon=pbParty(0)[index]
    return unless mon && mon.able? && pbIsOwner?(0,index)
    return unless KIFModernParty.exp_recipient?(mon,foe.participants.include?(index),shares,index)
    exp=KIFModernParty.reward(mon,foe.pokemon,foe.participants.include?(index))
    candies=0
    if respond_to?(:kif_level_cap_active?) && kif_level_cap_active?(mon)
      exp,candies=kif_apply_level_cap(mon,exp,mon.growth_rate)
    elsif $PokemonSystem.level_caps==1 && pokemonExceedsLevelCap(mon)
      exp=0
    end
    row=KIFModernParty.award(mon,exp)
    mon.calc_stats
    if (battler=pbFindBattler(index))
      if row
        pbDisplayPaused(_INTL('{1} gained {2} Exp. Points!',mon.name,row[:exp]))
        growth=mon.growth_rate
        current=row[:old_exp]
        row[:old_level].upto(mon.level) do |level|
          break if current>=mon.exp || level>=GameData::GrowthRate.max_level
          low=growth.minimum_exp_for_level(level);high=growth.minimum_exp_for_level(level+1)
          finish=[high,mon.exp].min
          @scene.pbEXPBar(battler,low,high,current,finish)
          current=finish
        end
        row[:native_active]=true
      end
      battler.pbUpdate(false);@scene.pbRefreshOne(battler.index)
    end
    # Active battlers keep native EXP dialogue/bar. Their left card is only
    # needed for a level-up or new-move lightbulb; benches always use the HUD.
    if row && (!battler || mon.level>row[:old_level] || !row[:moves].empty?)
      (@kmp_exp_rows||=[])<<row
    end
    kif_give_cap_candies(mon,candies) if candies>0
  end
end)

# Native battle/candy checks already defer evolution when this flag is true.
# The party action still runs the full native evolution scene and conditions.
Pokemon.prepend(Module.new do
  def evolve_from_party;true;end
  def check_evolution_on_level_up(prompt_choice=true)
    data=species_data
    return super unless data.is_a?(GameData::FusedSpecies)
    parents=[data.body_pokemon,data.head_pokemon]
    targets=parents.map do |parent|
      target=check_evolution_internal(parent) do |pokemon,new_species,method,parameter|
        GameData::Evolution.get(method).call_level_up(pokemon,parameter) ? new_species : nil
      end
      target ? KIFModernParty.evolved_parent(parent,target) : nil
    end
    return nil if targets.compact.empty?
    side=targets[1] ? 1 : 0
    if targets.all? && prompt_choice
      choices=[_INTL('Head: {1}',parents[1].name),_INTL('Body: {1}',parents[0].name),_INTL('Cancel')]
      choice=pbMessage(_INTL('Both halves of {1} are ready. Which half should evolve?',name),choices,2)
      return nil unless [0,1].include?(choice)
      side=choice==0 ? 1 : 0
    end
    # Eligibility-only calls are deterministic and never ask or consume RNG.
    body=side==0 ? targets[0] : parents[0]
    head=side==1 ? targets[1] : parents[1]
    getFusionSpecies(body,head).id
  end
end)
Object.prepend(Module.new do
  def pbChangeLevel(pokemon,*args)
    previous=KIFModernParty.evolution_moves;KIFModernParty.evolution_moves=pokemon
    super
  ensure
    KIFModernParty.evolution_moves=previous
  end
  def pokemonAllowedToEvolve(pokemon)
    pokemon && pokemon.able? && !pokemon.hasItem?(:EVERSTONE) && !!pokemon.check_evolution_on_level_up(false)
  end
  def pbLearnMove(pokemon,move,*args,&block)
    if KIFModernParty.evolution_moves.equal?(pokemon)
      KIFModernParty.unlock(pokemon,[move]);return false
    end
    super
  end
end)
KIF::LevelCap.singleton_class.prepend(Module.new do
  def release(pokemon,show)
    return unless pokemon && !pokemon.egg? && pokemon.kif_banked_exp.to_i>0
    give=[pokemon.kif_banked_exp,room(pokemon)].min
    return if give<=0
    pokemon.kif_banked_exp-=give
    row=KIFModernParty.award(pokemon,give)
    KIFModernParty.show([row]) if show
  end
end)
PokemonEvolutionScene.prepend(Module.new do
  def pbEvolutionSuccess(*args)
    previous=KIFModernParty.evolution_moves;KIFModernParty.evolution_moves=@pokemon
    result=super
    moves=Array(@pokemon.instance_variable_get(:@kmp_available_moves))
    KIFModernParty.show([{pokemon:@pokemon,old_exp:@pokemon.exp,old_level:@pokemon.level,old_fraction:@pokemon.exp_fraction,exp:0,moves:moves}]) unless moves.empty?
    result
  ensure
    KIFModernParty.evolution_moves=previous
  end
end)
if defined?(PokemonEvolutionSceneEBDX)
  PokemonEvolutionSceneEBDX.prepend(Module.new do
    def pbEvolution(*args)
      previous=KIFModernParty.evolution_moves;KIFModernParty.evolution_moves=@pokemon
      old_species=@pokemon.species
      result=super
      if @pokemon.species!=old_species
        moves=Array(@pokemon.instance_variable_get(:@kmp_available_moves))
        KIFModernParty.show([{pokemon:@pokemon,old_exp:@pokemon.exp,old_level:@pokemon.level,old_fraction:@pokemon.exp_fraction,exp:0,moves:moves}]) unless moves.empty?
      end
      result
    ensure
      KIFModernParty.evolution_moves=previous
    end
  end)
end
KIF::MoveLearning.singleton_class.prepend(Module.new do
  def change_moves_list(pokemon)
    (super+Array(pokemon.instance_variable_get(:@kmp_unlocked_moves))).uniq.reject { |id| pokemon.hasMove?(id) }
  end
end)
PokemonPartyScreen.prepend(Module.new do
  def pbRememberMoves(pokemon)
    result=super
    pokemon.instance_variable_set(:@kmp_available_moves,[]) if result
    result
  end
end)

# Lightweight pixel UI using native species artwork, including forms/fusions.
class KIFModernExpHUD
  attr_reader :age, :cards, :notice
  WIDTH=188
  HEIGHT=39
  def initialize(rows)
    @rows=rows;@age=0;@disposed=false;@cards=[];@art=[]
    @viewport=Viewport.new(0,0,Graphics.width,Graphics.height);@viewport.z=999999
    rows.first(6).each_with_index do |row,i|
      sprite=Sprite.new(@viewport);sprite.bitmap=Bitmap.new(WIDTH+55,HEIGHT)
      sprite.y=12+i*(HEIGHT+3);@cards<<sprite
      art=GameData::Species.sprite_bitmap_from_pokemon(row[:pokemon])
      @art<<art
    end
    @notice=Sprite.new(@viewport);@notice.bitmap=Bitmap.new(Graphics.width-24,50)
    @notice.x=12;@notice.y=Graphics.height-62
    @messages=rows.flat_map { |r| r[:moves].map { |id| "#{r[:pokemon].name}: #{GameData::Move.get(id).name}" } }
    @duration=150+@messages.length*90
    update
  end
  def disposed?;@disposed;end
  def dispose
    return if @disposed
    (@cards+[@notice]).each { |s| s.bitmap.dispose;s.dispose }
    @art.each(&:dispose);@viewport.dispose;@disposed=true
  end
  def text(bmp,string,x,y,w,size,color,align=0)
    pbSetSystemFont(bmp);bmp.font.size=size;bmp.font.color=color
    bmp.font.size-=1 while bmp.font.size>14 && bmp.text_size(string).width>w
    bmp.draw_text(x,y,w,22,string,align)
  end
  def update_audio
    # One shared EXP voice, rather than six overlapping copies. Active battle
    # bars already play their own native EXP/level sounds before this HUD.
    if @age==19 && @rows.any? { |r| !r[:native_active] && r[:exp]>0 }
      pbSEPlay('Pkmn exp gain')
    end
    @audio_levels||=@rows.map { |r| r[:old_level] }
    @rows.each_with_index do |row,i|
      next if row[:native_active] || row[:exp]<=0
      mon=row[:pokemon];t=[[@age-18,0].max/60.0,1.0].min
      progress=row[:old_fraction]+((mon.level-row[:old_level])+mon.exp_fraction-row[:old_fraction])*t
      level=t>=1 ? mon.level : [row[:old_level]+progress.floor,mon.level].min
      @level_sound_pending=true if level>@audio_levels[i]
      @audio_levels[i]=level
    end
    # Nearby simultaneous level crossings share a cue; a large multi-level
    # award must not restart the same sound on every render frame.
    if @level_sound_pending && @age-(@level_sound_at || -1000)>=6
      pbSEPlay('Pkmn exp full');@level_sound_at=@age;@level_sound_pending=false
    end
    pbSEPlay('Pkmn move learnt') if @age==85 && !@messages.empty?
    # Subsequent move notices each get their cue; the first was the lightbulb.
    if @age>150 && (@age-150)%90==0 && (@age-150)/90<@messages.length
      pbSEPlay('Pkmn move learnt')
    end
  end
  def update
    return if disposed?
    @age+=1
    return dispose if @age>=@duration
    update_audio
    white=Color.new(255,255,255);gold=Color.new(255,210,48);cyan=Color.new(65,215,245)
    @cards.each_with_index do |sprite,i|
      row=@rows[i];mon=row[:pokemon];b=sprite.bitmap;b.clear
      t=[[@age-18,0].max/60.0,1.0].min
      total=(mon.level-row[:old_level])+mon.exp_fraction-row[:old_fraction]
      progress=row[:old_fraction]+total*t
      shown_level=(row[:native_active] || t>=1) ? mon.level : [row[:old_level]+progress.floor,mon.level].min
      up=shown_level>row[:old_level]
      evolution_ready=up && row[:evolution_level] && shown_level>=row[:evolution_level]
      ink=evolution_ready ? Color.new(52,43,20) : white
      b.fill_rect(0,0,WIDTH,HEIGHT,up ? gold : Color.new(105,128,143,210))
      b.fill_rect(1,1,WIDTH-2,HEIGHT-2,evolution_ready ? Color.new(239,197,69,245) : up ? Color.new(12,101,144,225) : Color.new(25,37,43,210))
      art=@art[i].bitmap
      b.stretch_blt(Rect.new(78,-9,55,55),art,Rect.new(0,0,art.height,art.height),180)
      title=up ? 'Lv. Up!' : mon.name
      text(b,title,6,1,WIDTH-12,18,evolution_ready ? ink : up ? gold : white)
      text(b,"Lv. #{shown_level}",6,15,85,16,ink)
      unless row[:native_active]
        text(b,"+#{row[:exp]}",110,15,74,16,evolution_ready ? ink : gold,2)
        b.fill_rect(5,HEIGHT-5,WIDTH-10,3,Color.new(12,20,27))
        # Cross each actual level boundary before settling at the final fraction.
        fraction=t>=1 ? mon.exp_fraction : progress%1.0
        b.fill_rect(5,HEIGHT-5,((WIDTH-10)*fraction).round,3,cyan)
      end
      KIFModernEvolution.arrow(b,WIDTH-1,3+Math.sin(@age*0.22).round) if evolution_ready
      if !row[:moves].empty? && @age.between?(85,145)
        x=WIDTH-1+(evolution_ready ? 28 : 0);y=3+Math.sin(@age*0.22).round
        b.fill_rect(x+2,y,21,24,white);b.fill_rect(x,y+2,25,20,white)
        4.times { |n| b.fill_rect(x+2,y+24+n,4-n,1,white) }
        b.fill_rect(x+9,y+5,8,10,gold);b.fill_rect(x+7,y+7,12,6,gold)
        b.fill_rect(x+11,y+15,4,3,gold);b.fill_rect(x+10,y+19,6,2,gold)
        [[11,1,2,3],[20,6,3,2],[4,6,3,2]].each { |dx,dy,w,h| b.fill_rect(x+dx,y+dy,w,h,gold) }
      end
      entrance=[@age/15.0,1].min;exit_t=[(@duration-@age)/15.0,1].min
      sprite.x=6-((1-[entrance,exit_t].min)*(WIDTH+61)).round
    end
    @notice.bitmap.clear
    if @age>=150 && !@messages.empty?
      index=[(@age-150)/90,@messages.length-1].min
      b=@notice.bitmap;b.fill_rect(0,0,b.width,b.height,Color.new(250,250,250,245))
      text(b,@messages[index],8,0,b.width-16,19,Color.new(45,48,58))
      text(b,'Available in Change Moves.',8,23,b.width-16,17,Color.new(45,48,58))
    end
  end
end
