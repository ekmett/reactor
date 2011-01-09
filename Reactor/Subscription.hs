{-# LANGUAGE DeriveDataTypeable #-}
module Reactor.Subscription
  ( Subscription(..)
  ) where

import Control.Applicative
import Reactor.Task
import Data.Monoid
import Data.Typeable

-- Like in real life, cancelling a subscription may not stop it from sending you stuff immediately!
newtype Subscription = Subscription { cancel :: Task () }
  deriving Typeable

instance Monoid Subscription where
  mempty = Subscription (return ())
  Subscription a `mappend` Subscription b = Subscription (a *> b)
