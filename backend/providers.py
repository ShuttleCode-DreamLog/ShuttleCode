# Adapters report every failed call with this one type, so the worker can map it to a task outcome (wiki 4.3.10).
class ProviderError(Exception):
    def __init__(self, category, temporary):
        super().__init__(category)
        self.category, self.temporary = category, temporary
