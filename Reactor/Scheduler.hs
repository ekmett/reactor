{-# LANGUAGE MagicHash #-}
module Reactor.Scheduler 
  ( Scheduler(..)
  , immediately
  , terminally
  , after
  ) where

import Reactor.Task
import Reactor.Time
import Data.Fixed
import Control.Concurrent
#ifdef __GLASGOW_HASKELL__
import GHC.Integer
import GHC.Int
#endif

-- | A scheduler provides a strategy for executing tasks asynchronously

data Scheduler = Scheduler 
  { schedule :: Task () -> Task ()
  , scheduleAfter:: Delta -> Task () -> Task () 
  }

delay :: Delta -> IO ()
delay d = do
  let d' = min d $ toInteger (maxBound :: Int)
  threadDelay $ fromIntegral d'
  when (d' /= d) $ delay (d - d')
  
-- | schedule on the local thread immediately. blocking if need-be
-- 
-- Example: Blocks for 60 seconds, then prints "Hello\n...\n"
-- 
-- > do
-- >   schedule (immediately `after` seconds 60) $ io $ putStrLn "Hello"
-- >   io $ putStrLn "..."
--

immediately  :: Scheduler
immediately = Scheduler id $ \(Delay us) task -> do
  io $ threadDelay us
  task

-- | schedule a task at the end of the current success continuation
-- 
-- Example: prints "...\n", finishes up any other work that has already been enqueued
--  before blocking for the remainder of 60 seconds and printing "Hello\n"
-- 
-- > do 
--     schedule (terminally `after` seconds 60) $ io $ putStrLn "Hello"
--     io $ putStrLn "..."

terminally :: Scheduler
terminally = Scheduler run runAfter where 
  run task = Task $ \ks _kf _e -> do
    ks ()
    task ks kf _e

  runAfter (Delay us) task = Task $ \ks _kf _e = do
    t <- getPOSIXTime
    ks ()
    t' <- getPOSIXTime
    let spent = ceiling $ (t' - t) * 1000000
    when (spent < us) $ delay (us - spent)
    task 

-- | schedule a task, but also drop it into the spark queue. This will enable it to
-- be grabbed opportunistically by other threads, but will do so in a queueing fashion.

sparking :: Scheduler
sparking = Scheduler run runAfter where

  parIO :: IO a -> IO a
  parIO m = x `par` return x where
    x = unsafePerformIO (noDuplicate >> m)

  run task = Task $ \ks _kf _e -> do
    x <- parIO m
    ks ()
    x `seq` return ()

  runAfter (Delay us) task = Task $ \ks _kf _e = do
    t <- getPOSIXTime
    ks ()
    t' <- getPOSIXTime
    let spent = ceiling $ (t' - t) * 1000000
    when (spent < us) $ delay (us - spent)
    run task 

after :: Scheduler -> Delta -> Scheduler
after (Scheduler s a) us = Scheduler (a us) (a . (us+))
