module Reactor.Observable
  ( Observable(..)
  , never
  , fby
  , take, drop
  , filterMap, (!?)
  , (<||>)
  -- , feed
  -- , head
  -- , safeHead
  ) where

import Prelude hiding (filter, take, drop)
import Control.Applicative
import Control.Exception hiding (handle)
import Control.Monad
import Control.Monad.Error
import Control.Monad.Reader
import Control.Monad.Cont
import Control.Monad.Trans
import Data.Array.IO
import Data.Foldable
import qualified Data.Foldable as Foldable
import Data.Functor.Apply
import Data.Monoid
import Data.IORef
import Reactor.Atomic
import Reactor.Contravariant
import qualified Reactor.Deque as Deque
import Reactor.Deque (Deque)
import Reactor.Filtered
import Reactor.Moore
import Reactor.Observer
import Reactor.Task
import Reactor.Subscription

newtype Observable a = Observable { subscribe :: Observer a -> Task Subscription }

safe :: Observable a -> Observable a 
safe p = Observable $ \o -> do
   alive <- atomic (1 :: Int)
   subscribe_ p
     (\a -> given alive $ o ! a)
     (\e -> clearing alive $ handle o e)
     (clearing alive $ complete o)

subscribe_ :: Observable a -> (a -> Task ()) -> (SomeException -> Task ()) -> Task () -> Task Subscription
subscribe_ a f h c = subscribe a (Observer f h c)

filterMap :: (a -> Maybe b) -> Observable a -> Observable b
filterMap p s = Observable $ \o -> subscribe s $ o ?! p

(!?) :: Observable a -> (a -> Maybe b) -> Observable b
(!?) = flip filterMap 

never :: Observable a
never = Observable $ \o -> return mempty

fby :: a -> Observable a -> Observable a 
fby a as = Observable $ \o -> do
  o ! a
  subscribe as o

take :: Int -> Observable a -> Observable a 
take n p = Observable $ \o -> do
  counter <- atomic n
  subscribe_ p 
    (\a -> do
      i <- io $ atomicSubAndFetch counter 1
      when (i >= 0) $ o ! a
      when (i == 0) $ complete o)
    (handle o)
    (do
      i <- io $ atomicFetchAndAnd counter 0
      when (i >= 0) $ complete o)
      
drop :: Int -> Observable a -> Observable a 
drop n p = Observable $ \o -> do
  counter <- atomic n
  subscribe_ p
    (\a -> do
      i <- io $ atomicSubAndFetch counter 1
      when (i < 0) $ o ! a)
    (handle o)
    (complete o)

instance Filtered Observable where
  filter p s = Observable (subscribe s . filter p)
  
instance Functor Observable where
  fmap f s = Observable (subscribe s . contramap f)

instance FunctorApply Observable where
  mf <.> ma = Observable $ \o -> do
    funs <- io $ newIORef []
    fflag <- atomic (1 :: Int)
    aflag <- atomic (1 :: Int)
    let discard pf sf = do
          i <- atomicFetchAndAnd pf 0
          when (i == 1) $ do
            j <- atomicFetch sf
            when (j == 0) $ complete o
    subscribe_ mf
      (\f -> io $ atomicModifyIORef funs (\fs -> (f:fs, ())))
      (handle o)
      (discard fflag aflag)
    subscribe_ ma
      (\a -> do
        fs <- io $ readIORef funs 
        spawn $ Foldable.mapM_ (\f -> o ! f a) fs)
      (handle o)
      (discard aflag fflag)

-- | observe both in parallel
(<||>) :: Observable a -> Observable a -> Observable a 
p <||> q = Observable $ \o -> mappend <$> subscribe p o <*> subscribe q o

instance Applicative Observable where
  pure a = Observable $ \o -> (o ! a) *> complete o $> mempty 
  (<*>) = (<.>)
        
instance Monad Observable where
  return a = Observable $ \o -> (o ! a) *> complete o $> mempty
  mf >>= k = Observable $ \o -> do
    counter <- atomic (1 :: Int)
    topFlag <- atomic (1 :: Int)
    let detach flag = do
          clearing topFlag $ do
            i <- atomicSubAndFetch counter 1
            when (i == 0) $ complete o
    subscribe_ mf 
      (\f -> do
        flag <- atomic (1 :: Int)
        atomicAddAndFetch counter 1 
        () <$ subscribe_ (k f)
          (o !)
          (handle o)
          (detach flag))
      (handle o)
      (detach topFlag)

instance Alternative Observable where
  empty = Observable (\o -> complete o $> mempty)
  a <|> b = Observable $ \o -> subscribe_ a
    (o !)
    (handle o)
    (subscribe b o $> ())

instance MonadPlus Observable where
  mzero = empty
  mplus = (<|>)

duplicateObservable :: Observable a -> Observable (Observable a)
duplicateObservable p = Observable $ \o -> subscribe_ p 
  (\a -> o ! fby a p)
  (handle o) 
  (complete o)

extendObservable :: (Observable a -> b) -> Observable a -> Observable b
extendObservable f p = Observable $ \o -> subscribe_ p 
  (\a -> o ! f (fby a p))
  (handle o)
  (complete o)


observe :: Foldable f => f a -> Observable a
observe t = Observable $ \o -> do
  spawn $ do
    Foldable.forM_ t (o !)
    complete o
  return mempty


counted :: Observable a -> Observable (Int, a)
counted p = Observable $ \o -> do
  counter <- atomic 0
  subscribe_ p 
    (\a -> do
      i <- atomicFetchAndAdd counter 1
      o ! (i, a))
    (handle o)
    (complete o)

-- do something when the observable completes

andThen :: Observable a -> Task () -> Task Subscription
andThen p t = spawn $ subscribe_ p
    (\_ -> return ())
    (\_ -> t)
    t

{-

feed :: Moore i o -> Observable i -> Task o
feed machine p = do
  m <- io $ newIORef machine
  callCC $ \resume -> 
    subscribe p 
      (\i -> io $ atomicModifyIORef m $ \m' -> (step m' i, ()))
      throwError 
      (do Moore _ o <- io $ readIORef m
          resume o)

safeHead :: Onservable a -> Task (Maybe a)
safeHead = feed (Moore (pure . Just) Nothing) . take 1

head :: Observable a -> Task a 
head = feed (Moore pure (error "head: empty observable")) . take 1

-- uncons :: Observable a -> Task (Maybe (a, Observable a))
-}
