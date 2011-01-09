module Reactor.Filtered where

import Prelude hiding (filter)
import qualified Prelude

class Filtered f where
  filter :: (a -> Bool) -> f a -> f a

instance Filtered [] where
  filter = Prelude.filter

