require 'test_helper'
require 'game'

class GameTest < ActiveSupport::TestCase

  def setup
    @game = Game.new(players: 4)
  end
   
  def test_initialize
    assert_equal 4, @game.players_count
  end
   
  def test_move_and_claim
    @game.move(player: 1, dice: 2, value: 3)
    @game.move(player: 2, dice: 1, value: 3)
    assert_equal "An outrageous claim ->  0.000000000508%", @game.claim(dice: 19, value: 3) 
  end
   
   
  def test_challange
    @game.move(player: 1, dice: 2, value: 3)
    @game.move(player: 2, dice: 1, value: 3)
    @game.move(player: 3, dice: 5, value: 3)
    @game.move(player: 4, dice: 5, value: 3)
    @game.move(player: 1, dice: 3, value: 3)
    @game.move(player: 2, dice: 3, value: 3)
    assert_equal "Well, maybe -> 16.67%", @game.claim(dice: 20, value: 3)
  end
  
  
  def test_invalid_move_params
    assert_equal "missing params, required format:  game.move(player: X, dice: X, value: X)", @game.move(dice: 2, value: 3)
    assert_equal "missing params, required format:  game.move(player: X, dice: X, value: X)", @game.move(player: 2, value: 3)
    assert_equal "missing params, required format:  game.move(player: X, dice: X, value: X)", @game.move(dice: 2, player: 3)
  end
  
  def test_invalid_claim_params
    assert_equal "missing params, required format:  game.claim(dice: X, value: X)" , @game.claim(value: 12)
    assert_equal "missing params, required format:  game.claim(dice: X, value: X)" , @game.claim(dice: 4)
  end
  
  def invalid_challange_claim_params
    assert_equal "missing params, required format:  game.challange(dice: X, value: X)"  , @game.challange(value: 12)
    assert_equal "missing params, required format:  game.challange(dice: X, value: X)"  , @game.challange(dice: 2)
  end
   
end
