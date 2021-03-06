{-# LANGUAGE DeriveDataTypeable #-}
module Reactor.Moore
  ( Moore(..)
  ) where

import Control.Applicative
import Control.Comonad
import Data.Functor.Apply
import Data.Typeable

data Moore i o = Moore { step :: i -> Moore i o, current :: o }
  deriving Typeable

instance Functor (Moore i) where
  fmap g (Moore f o) = Moore (fmap g . f) (g o)
  b <$ _ = pure b

instance Extend (Moore i) where
  duplicate m = Moore (duplicate . step m) m
  extend g m = Moore (extend g . step m) (g m)

instance Comonad (Moore i) where
  extract (Moore _ o) = o
  
instance Apply (Moore i) where
  Moore ff f <.> Moore fa a = Moore (\i -> ff i <.> fa i) (f a)
  a <. _ = a
  _ .> b = b

instance Applicative (Moore i) where
  pure o = m where m = Moore (const m) o
  (<*>) = (<.>)
  (<* ) = (<. )
  ( *>) = ( .>)
