{-# LANGUAGE DeriveDataTypeable #-}
module Reactor.Time where

import Data.Data

newtype Delta = Delta Integer
  deriving (Data,Typeable,Show,Read,Eq,Ord)

days :: Integer -> Delta
days = hours . (24*)

hours :: Integer -> Delta
hours = minutes . (60*)

minutes :: Integer -> Delta
minutes = seconds . (60*)

seconds :: Integer -> Delta
seconds = Delta . (1000000*)

milliseconds :: Integer -> Delta
milliseconds = Delta . (1000*)

microseconds :: Integer -> Delta
microseconds = Delta

nanoseconds :: Integer -> Delta
nanoseconds = Delta . (`div` 1000)

