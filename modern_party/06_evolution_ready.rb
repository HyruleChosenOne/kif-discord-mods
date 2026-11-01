module KIFModernEvolution
  def self.ready?(pokemon)
    pokemon && !pokemon.egg? && pokemon.able? && !pokemon.hasItem?(:EVERSTONE) &&
      !(pokemon.respond_to?(:kif_evo_locked?) && pokemon.kif_evo_locked?) &&
      !!pokemon.check_evolution_on_level_up(false)
  end
  def self.first_ready_level(row)
    mon=row[:pokemon]
    return nil unless mon.level>row[:old_level] && ready?(mon)
    ((row[:old_level]+1)..mon.level).find do |level|
      probe=mon.clone
      probe.level=level
      ready?(probe)
    end
  end
  def self.arrow(bitmap,x,y)
    white=Color.new(255,255,255);yellow=Color.new(255,210,48)
    bitmap.fill_rect(x+2,y,21,24,white);bitmap.fill_rect(x,y+2,25,20,white)
    4.times { |n| bitmap.fill_rect(x+2,y+24+n,4-n,1,white) }
    6.times { |n| bitmap.fill_rect(x+12-n,y+4+n,1+2*n,1,yellow) }
    bitmap.fill_rect(x+9,y+10,7,10,yellow)
  end
  def self.party_arrow(bitmap,x=236,y=65)
    dark=Color.new(92,63,10);yellow=Color.new(255,218,48)
    7.times { |n| bitmap.fill_rect(x+6-n,y+n,1+n*2,1,dark) }
    bitmap.fill_rect(x+3,y+7,7,10,dark)
    5.times { |n| bitmap.fill_rect(x+6-n,y+2+n,1+n*2,1,yellow) }
    bitmap.fill_rect(x+4,y+7,5,9,yellow)
  end
end
KIFModernExpHUD.prepend(Module.new do
  def initialize(rows)
    rows.each { |row| row[:evolution_level]=KIFModernEvolution.first_ready_level(row) }
    super
  end
end)
PokemonPartyPanel.prepend(Module.new do
  def refresh
    return super if @refreshing || disposed?
    cue=!@switching && !@preselected && KIFModernEvolution.ready?(@pokemon)
    @refreshBitmap=true if @kmp_evolution_cue!=cue
    @kmp_evolution_cue=cue
    super
    if cue && @panelbgsprite && !@panelbgsprite.disposed?
      @panelbgsprite.color=Color.new(255,218,65,@selected ? 220 : 195)
      KIFModernEvolution.party_arrow(@overlaysprite.bitmap) if @overlaysprite && !@overlaysprite.disposed?
    end
  end
end)
Window_CommandPokemonColor.prepend(Module.new do
  def drawItem(index,count,rect)
    if @commands && @commands[index]==_INTL('Evolve!')
      pbSetSystemFont(self.contents) if @starting
      text_rect=drawCursor(index,rect)
      pbDrawShadowText(self.contents,text_rect.x,text_rect.y,text_rect.width,text_rect.height,
        @commands[index],Color.new(255,210,48),Color.new(80,56,8))
      return
    end
    super
  end
end)
