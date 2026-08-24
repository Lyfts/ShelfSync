local Hardcover = {
  STATUS = {
    TO_READ = 1,
    READING = 2,
    FINISHED = 3,
    PAUSED = 4,
    DNF = 5,
  },
  STATUS_NAME = {
    [1] = "Want To Read",
    [2] = "Currently Reading",
    [3] = "Read",
    [4] = "Paused",
    [5] = "Did Not Finish",
  },
  CATEGORY = {
    TAG = "Tag",
  },
  ERROR = {
    JWT = "invalid-jwt",
    TOKEN = "Unable to verify token",
  }
}

return Hardcover
