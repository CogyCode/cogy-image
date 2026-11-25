"""The error raised when the image service refuses or cannot serve a request."""


class InspectError(Exception):
    """A failed request, with the HTTP status to answer it with."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message
