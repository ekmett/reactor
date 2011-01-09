{-# LANGUAGE DeriveDataTypeable #-}
module Reactor.Observer
  ( Observer(..)
  , (?!)
  ) where

import Prelude hiding (filter)
import Control.Monad
import Control.Exception hiding (handle)
import Control.Monad.Error
import Data.Monoid
import Reactor.Contravariant
import Reactor.Filtered
import Reactor.Task
import Data.Data

data Observer a = Observer 
  { (!)      :: a -> Task ()
  , handle   :: SomeException -> Task ()
  , complete :: Task ()
  } deriving Typeable

instance Contravariant Observer where
  contramap g (Observer f h c) = Observer (f . g) h c

instance Filtered Observer where
  filter p (Observer f h c) = Observer (\a -> when (p a) (f a)) h c

instance Monoid (Observer a) where
  mempty = Observer (\_ -> return ()) throwError (return ())
  p `mappend` q = Observer
    (\a -> do p ! a; q ! a)
    (\e -> do handle p e; handle q e)
    (do complete p; complete q)

-- filter and map in one operation
(?!) :: Observer b -> (a -> Maybe b) -> Observer a
Observer f h c ?! p = Observer (maybe (return ()) f . p) h c
