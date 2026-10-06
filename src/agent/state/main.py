from typing import TypedDict

from langgraph.graph import MessagesState


class State(MessagesState):
    user_preference: dict
    user_intent: str


class NeedReserveOutput(TypedDict):
    reserve: str