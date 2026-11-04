# User-supplied auto-battle formula. Simulation changes local HP only.
module KIFModernAutoCombat
  def self.attack_profile(attacker,defender)
    attacker.types.flat_map do |type|
      raw=Effectiveness.calculate(type,*defender.types)/Effectiveness::NORMAL_EFFECTIVE.to_f
      effectiveness=raw<=0 ? 0.5 : raw
      resisted=defender.types.all? do |defending_type|
        Effectiveness.calculate(type,defending_type)<Effectiveness::NORMAL_EFFECTIVE
      end
      power=resisted ? 30 : 40
      [[:physical,attacker.attack,defender.defense],[:special,attacker.spatk,defender.spdef]].map do |category,attack,defense|
        base=((2.0*attacker.level/5+2)*attack*power)/(50.0*defense+2)*1.5*effectiveness
        {type:type,category:category,power:power,effectiveness:effectiveness,base_damage:base}
      end
    end.max_by { |profile| profile[:base_damage] }
  end
  def self.hit(profile,rng)
    [(profile[:base_damage]*(0.85+rng.rand*0.15)).floor,1].max
  end
  def self.hp_loss_percent(won,remaining,total)
    return 50 unless won
    return 0 if remaining*4>=total*3
    return 5 if remaining*2>=total
    return 10 if remaining*4>=total
    25
  end
  def self.simulate(hero,foe,rng=Random)
    hero_hp=hero.hp;foe_hp=foe.hp
    hero_attack=attack_profile(hero,foe);foe_attack=attack_profile(foe,hero)
    first=hero.speed>foe.speed || (hero.speed==foe.speed && rng.rand<0.5)
    rounds=0
    while hero_hp>0 && foe_hp>0
      rounds+=1
      if first
        foe_hp-=hit(hero_attack,rng)
        hero_hp-=hit(foe_attack,rng) if foe_hp>0
      else
        hero_hp-=hit(foe_attack,rng)
        foe_hp-=hit(hero_attack,rng) if hero_hp>0
      end
    end
    won=hero_hp>0
    percent=hp_loss_percent(won,[hero_hp,0].max,hero.totalhp)
    # Fractions of an HP round upward; a quick battle never faints the lead.
    loss=(hero.totalhp*percent/100.0).ceil
    {won:won,remaining_hp:[hero_hp,0].max,hp_loss_percent:percent,damage:loss,
      rounds:rounds,hero_attack:hero_attack,foe_attack:foe_attack}
  end
end
