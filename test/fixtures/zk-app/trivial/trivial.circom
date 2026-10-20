pragma circom 2.0.0;

template Trivial() {
    signal input x;   // private
    signal input y;   // public
    y === x * x;
}

component main {public [y]} = Trivial();
