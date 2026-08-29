#include "mpi.h"
#include <stdio.h>
#include <iostream>    
#include <algorithm>   
#include <vector>      
#include <cstring>     
using namespace std;

bool is_power_of_two(int x) {
    return x > 0 && (x & (x - 1)) == 0;
}

static void take_low(const int*x, const int*y, int*out,int n)
{
    int i=0;
    int j=0;
    for(int k=0;k<n;k++)
    {
        out[k]= (x[i] <= y[j]) ? x[i++] : y[j++];
    }
}

static void take_high(const int*x, const int*y, int*out,int n)
{
    int i=n-1;
    int j=n-1;
    for(int k=n-1;k>=0;k--)
    {
        out[k]= (x[i] >= y[j]) ? x[i--] : y[j--];
    }
}

int main(int argc, char*argv[])
{
    int rank,p,n;
    MPI_Init(&argc,&argv);
    MPI_Comm_rank(MPI_COMM_WORLD,&rank);
    MPI_Comm_size(MPI_COMM_WORLD, &p);

    if (rank == 0) {
        cin >> n;

    }



    MPI_Bcast(&n, 1, MPI_INT, 0, MPI_COMM_WORLD);

    if(!is_power_of_two(n) || !is_power_of_two(p) || n%p != 0)
    {
        if(rank==0)
        {
            cerr << "error: N and P must be a power of two with N divisible by P\n";
        }
        MPI_Finalize();
        return 1;
    }

    int *data = nullptr;
    if (rank == 0) {
        data = new int[n];
        for (int i = 0; i < n; i++)
        {
            cin >> data[i];
        }

    }

    int m = n / p;
    int *local = new int[m];

    MPI_Scatter(data, m, MPI_INT, local, m, MPI_INT, 0, MPI_COMM_WORLD);

    sort(local,local+m);
    


    vector<int> bufA(m), bufB(m), bufC(m);
    int *mine   = bufA.data();   
    int *theirs = bufB.data();   
    int *merged = bufC.data();

    memcpy(mine,local,m*sizeof(int));
    for( int k=2;k<=p;k<<=1)
    {
        for(int j=k>>1; j>0; j>>=1)
        {
            int partner= rank^j;
            bool ascending= ((rank &k)==0);
            bool keep_low= ((rank < partner) == ascending);



            MPI_Sendrecv(mine, m, MPI_INT, partner, 0,
                         theirs, m, MPI_INT, partner, 0,
                         MPI_COMM_WORLD, MPI_STATUS_IGNORE);


            if(keep_low)
            {
                take_low(mine, theirs, merged, m);
            }
            else
            {
                take_high(mine, theirs, merged, m);
            }

            memcpy(mine, merged, m*sizeof(int));



        }

    }
    vector<int> result;
    if (rank == 0) result.resize(n);

    MPI_Gather(mine,m,MPI_INT, rank==0 ? result.data(): nullptr,m,MPI_INT,0,MPI_COMM_WORLD);

    if (rank == 0) {
        for (int i = 0; i < n; i++)
        {
            printf("%d ", result[i]);
            
        }
        printf("\n");
    }

    MPI_Finalize();
    return 0;

}