module Reactor.Observable
  ( Observable(..)
  , never
  , fby
  , take, drop
  , safe
  , filterMap, (!?)
  , observe
  , counted
  -- , andThen
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
import Data.Foldable
import qualified Data.Foldable as Foldable
import Data.Functor.Bind
import Data.Functor.Plus
import Data.Functor.Extend
import Data.Functor.Contravariant
import Data.Monoid
import Data.IORef
import Reactor.Atomic
import Reactor.Filtered
import Reactor.Observer
import Reactor.Task
import Reactor.Subscription

newtype Observable a = Observable { subscribe :: Observer a -> Task Subscription }

instance Functor Observable where
  fmap f s = Observable (subscribe s . contramap f)

instance Apply Observable where
  mf <.> ma = Observable $ \o -> do
    funs <- io $ newIORef []
    fflag <- atomic (1 :: Int)
    aflag <- atomic (1 :: Int)
    let discard pf sf = do
          i <- atomicFetchAndAnd pf 0
          when (i == 1) $ do
            j <- atomicFetch sf
            when (j == 0) $ complete o
    mappend 
      <$> subscribe_ mf
            (\f -> io $ atomicModifyIORef funs (\fs -> (f:fs, ())))
            (handle o)
            (discard fflag aflag)
      <*> subscribe_ ma
            (\a -> do
              fs <- io $ readIORef funs 
              spawn $ Foldable.mapM_ (\f -> o ! f a) fs)
            (handle o)
            (discard aflag fflag)

instance Filtered Observable where
  filter p s = Observable (subscribe s . filter p)

instance Applicative Observable where
  pure a = Observable $ \o -> (o ! a) *> complete o $> mempty 
  (<*>) = (<.>)

instance Bind Observable where
  mf >>- k = Observable $ \o -> do
    counter <- atomic (1 :: Int)
    topFlag <- atomic (1 :: Int)
    let detach flag = do
          clearing flag $ do
            i <- atomicSubAndFetch counter 1
            when (i == 0) $ complete o
    subscribe_ mf 
      (\f -> do
        flag <- atomic (1 :: Int)
        _ <- atomicAddAndFetch counter 1 
        () <$ subscribe_ (k f)
          (o !)
          (handle o)
          (detach flag))
      (handle o)
      (detach topFlag)
        
instance Monad Observable where
  return = pure
  (>>=) = (>>-)

instance Alt Observable where
  a <!> b = Observable $ \o -> subscribe_ a
    (o !)
    (handle o)
    (subscribe b o $> ())

instance Plus Observable where
  zero = Observable (\o -> complete o $> mempty)
  
instance Alternative Observable where
  empty = zero
  (<|>) = (<!>)

instance MonadPlus Observable where
  mzero = zero
  mplus = (<!>)

instance Extend Observable where
  duplicate p = Observable $ \o -> subscribe_ p 
    (\a -> o ! fby a p)
    (handle o) 
    (complete o)
  extend f p = Observable $ \o -> subscribe_ p 
    (\a -> o ! f (fby a p))
    (handle o)
    (complete o)

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
never = Observable $ \_ -> return mempty

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

-- | Observe both at the same time.
(<||>) :: Observable a -> Observable a -> Observable a 
p <||> q = Observable $ \o -> mappend <$> subscribe p o <*> subscribe q o

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

{-
andThen :: Observable a -> Task () -> Task ()
andThen p t = spawn $ do
  () <$ subscribe_ p (\_ -> return ()) (\_ -> t) t
-}

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
