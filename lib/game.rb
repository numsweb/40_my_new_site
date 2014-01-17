class Game

  ################################################################
  #An example execution might be:
  #require "game"
  #game = Game.new(players: 4)
  #game.move(player: 1, dice: 2, value: 3)
  #game.move(player: 2, dice: 1, value: 3)
  #game.claim(dice: 19, value: 3) 
  #    result:  An outrageous claim! -> 0.000000000516%
  #
  #
  ##  Now if we do this:
  #game.move(player: 3, dice: 5, value: 3)
  #game.move(player: 4, dice: 5, value: 3)
  #game.move(player: 1, dice: 3, value: 3)
  #game.move(player: 2, dice: 3, value: 3)
  ## There are 19 3's on the board.
  #game.claim(dice: 20, value: 3)
  ##1! / 1!0! * 1/6^1 * 5/6^0 = 16.67%
  ################################################################
  def initialize(players)
    @players = players[:players].to_i
    #initialize a hash of counters for each dice and the total_used
    @counters = {1 => 0, 2 => 0, 3 => 0, 4 => 0, 5 => 0, 6 => 0, :total_used => 0 }
  end
  
  def players_count
    return @players
  end

  def move(params)
    if params[:player].blank? || params[:dice].blank? || params[:value].blank?
      puts "missing params, required format:  game.move(player: X, dice: X, value: X)"
      return "missing params, required format:  game.move(player: X, dice: X, value: X)"
    else
      player = params[:player].to_i #the players number
      dice = params[:dice].to_i #the number of dice for this move
      value = params[:value].to_i #the number on the dice (1-6)
    
      #just check that we have that many players
      if player > @players
        puts "invalid player"
      else
        #first make sure we haven't used up all the dice
        #TODO we should really keep track of how many dice were used by each player
        #and verify they haven't exceeded their 5
        if (@counters[:total_used] + params[:dice].to_i)  >= (@players * 5)
          raise "sorry all the dice are already used in this game!"
        end
        
        #check for valid dice value
        if value > 6
          raise "sorry, that is an invalid value for the dice!"
        end
        
        #update the running totals
        @counters[value] = @counters[value] +  dice
        
        #update the total
        @counters[:total_used] = @counters[:total_used] + dice
      end
    end
  end
  
  def claim(params)
    if params[:dice].blank? || params[:value].blank?
      puts "missing params, required format:  game.claim(dice: X, value: X)"
      return "missing params, required format:  game.claim(dice: X, value: X)" 
    else
      probability = check_probability(params[:dice].to_i, params[:value].to_i)
    end
    return probability
  end
  
  def challange(params)
    if params[:dice].blank? || params[:value].blank?
      puts "missing params, required format:  game.challange(dice: X, value: X)"
      return "missing params, required format:  game.challange(dice: X, value: X)" 
    else
      value = params[:value].to_i #the number on the dice (1-6)
      total_used = get_count_for_value(value)
      return params[:dice].to_i <= total_used
    end
  end
  
  
  private
  
  def get_count_for_value(value)
    return @counters[value]
  end
  
  def factorial(number)
    #here we compute a factorial for the number
    #use ennumerable to multiply by each item in the collection to get a factorial
    #since we don't specify an initial value, the first item in the collection is used for the initial value
    #kudos to http://rosettacode.org/wiki/Factorial#Ruby
    (1..number).reduce(:*) || 1
  end
  
  def check_probability(dice,value)
    #here we run the computation to determine what the probability is and compose a message to print on the screen.
    #dice is the claimed number of occurances
    #value is the value on the dice face (1-6 dots)

    total_used = get_count_for_value(value)
    total_dice = @players * 5 #each player has a cup of 5 dice
    remaining_required = dice - total_used
    remaining = total_dice - @counters[:total_used] #Important, here we use the class variable to get the total of all dice used, not the local variable which is the count for the specific dice we are evaluating.
    rem = remaining #make a separate copy for decrementing
    iterations = (remaining - remaining_required) + 1
    
    #iterate through remaining down to required
    resulting_probability = 0.0
    fact = 0.0
    while iterations > 0
      #this was just a sanity check of the calculation to make sure the formula is correct.It is not used.
      #check_calc = factorial(17.0)/(factorial(16.0)*factorial(1.0)) * ((1.0/6.0)**16) * (5.0/(6.0**1))
      this_pass = factorial(remaining.to_f)/(factorial(rem.to_f) * factorial(fact.to_f)) * ((1.0/6.0)**rem.to_f * (5.0/6.0)**fact.to_f)
      resulting_probability += this_pass
      iterations -= 1
      rem -= 1
      fact += 1
    end
    
    #convert to a percentage 
    resulting_probability = resulting_probability * 100
    
    #make some different strings for the different probability ranges.
    if (resulting_probability < 0.00000000001)
      output_string="A snowball's chance in hell ->  #{resulting_probability.round(15).to_s}%"
    elsif(resulting_probability > 0.00000000001) && (resulting_probability < 0.000001)
      #have to format to keep rails from using scientific notation!
      output_string="An outrageous claim ->  #{ "%1.12f" % resulting_probability.to_s}%"
    elsif (resulting_probability > 0.000001) && (resulting_probability < 0.01)
      output_string="Pretty slim pickings ->  #{resulting_probability.round(6).to_s}%"
    elsif (resulting_probability > 1.000001) && (resulting_probability < 50.0)
      output_string="Well, maybe -> #{resulting_probability.round(2).to_s}%"
    else
      #if we get to here its better than 50/50
      output_string="Darn, thats a pretty good chance -> #{resulting_probability.round(20).to_s}%"
    end
    
    #print the answer string
    puts output_string
    return output_string
  end
    

end
