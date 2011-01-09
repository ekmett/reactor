module Reactor.Filtered where

import Prelude hiding (filter)
import qualified Prelude

class Filtered f where
  filter :: (a -> Bool) -> f a -> f a

instance Filtered [] where
  filter = Prelude.filter

instance Filtered Maybe where
  filter p m@(Just a) | p a = m
  filter _ _ = Nothing
