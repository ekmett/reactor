{-# LANGUAGE MultiParamTypeClasses, DeriveDataTypeable #-}
module Reactor.Task
  ( Task
  , run
  , spawn
  , io
  ) where

import Control.Applicative
import Control.Monad
import Control.Exception
import Control.Monad.Reader.Class
import Control.Monad.Error.Class
import Control.Monad.IO.Class
import Data.Array.IO
import Data.Functor.Bind
import Data.Functor.Plus
import Reactor.Deque (Deque)
import Data.Data
import qualified Reactor.Deque as Deque

newtype Env = Env { envDeque :: Deque IOArray (Task ()) }

mkEnv :: IO Env 
mkEnv = Env <$> Deque.empty

newtype Task a = Task 
  { runTask :: (a -> IO ()) -> 
               (SomeException -> IO ()) -> 
               (Env -> IO ())
  } deriving Typeable

instance Functor Task where
  fmap f (Task m) = Task $ \ks -> m (ks . f)

instance Apply Task where
  Task mf <.> Task ma = Task $ \ks kf e -> mf (\f -> ma (ks . f) kf e) kf e

instance Applicative Task where 
  pure a = Task (\ks _kf _e -> ks a)
  (<*>) = (<.>) 

instance Bind Task where
  Task mf >>- k = Task (\ks kf e -> mf (\a -> runTask (k a) ks kf e) kf e)
  
instance Monad Task where
  return = pure
  (>>=) = (>>-)

instance MonadReader Env Task where
  ask = Task (\ks _kf e -> ks e)
  local f (Task ma) = Task (\ks kf e -> ma ks kf (f e))

instance MonadIO Task where
  liftIO = io

io :: IO a -> Task a 
io act = Task (\ks _kf _e -> act >>= ks)

instance MonadError SomeException Task where
  throwError err = Task (\_ks kf _e -> kf err)
  catchError (Task m) h = Task (\ks kf e -> m ks (\err -> runTask (h err) ks kf e) e)

instance Alt Task where
  Task ma <!> Task mb = Task (\ks kf e -> ma ks (\_ -> mb ks kf e) e)

instance Plus Task where
  zero = Task (\_ks kf _e -> kf (toException (ErrorCall "empty")))

instance Alternative Task where
  (<|>) = (<!>)
  empty = zero

instance MonadPlus Task where
  mzero = zero
  mplus = (<!>)

spawn :: Task () -> Task ()
spawn task = Task (\_ks _kf e -> Deque.push task (envDeque e))

-- run a single threaded pump, all tasks are placed locally
run :: Task () -> IO ()
run task0 = do
  env <- mkEnv
  bracket_
    (register env)
    (go env task0)
    (unregister env)
  where
    go :: Env -> Task () -> IO ()
    go env (Task m) = m (success env) (failure env) env
    success env _ = Deque.pop (envDeque env) >>= maybe (return ()) (go env)
    failure _env = throw -- TODO: shut down workers?
    register _env = return () -- TODO: start up if necessary and tell worker threads about us
    unregister _env = return () -- TODO: shutdown if necessary and tell worker threads about us

