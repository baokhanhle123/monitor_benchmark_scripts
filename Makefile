CXX      = g++
CXXFLAGS = -O2 -Wall -Wextra -std=c++17

spawner: spawner.cpp
	$(CXX) $(CXXFLAGS) -o spawner spawner.cpp

clean:
	rm -f spawner

.PHONY: clean
