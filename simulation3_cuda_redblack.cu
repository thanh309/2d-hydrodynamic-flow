// #include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>


// Constants and parameters
const int scale = 2;
const double length_x = 1.0;
const double length_y = 2.0;
const int nx = 50 * scale;
const int ny = 100 * scale;
const double dx = length_x / nx;
const double dy = length_y / ny;
const double Re = 0.05;
const double U = 1.0;
const double L = 1.0;
const double nu = U * L / Re;
const double dt = 0.000001;
const double div_tolerance = 1e-3;
const double beta0 = 1.0;
const int max_iterations = 200;
const double total_time = 0.001;
const double beta = beta0 / (2*dt*(1 / (dx*dx) + 1 / (dy*dy)));

const int max_number_of_frames = 50;

// Inlet and outlet positions
const int inlet_start = scale * (44 - 2);
const int inlet_end = scale * (56 + 2);
const int outlet1_start = scale * (10 - 2);
const int outlet1_end = scale * (23 + 2);
const int outlet2_start = scale * (44 - 2);
const int outlet2_end = scale * (56 + 2);
const int outlet3_start = scale * (77 - 2);
const int outlet3_end = scale * (90 + 2);

#define s_d sizeof(double)
#define s_i sizeof(int)
#define s_i16 sizeof(uint16_t)

// CUDA error checking macro
#define CUDA_CHECK_ERROR(call)                                             \
    {                                                                      \
        cudaError_t err = call;                                            \
        if (err != cudaSuccess) {                                          \
            fprintf(stderr, "CUDA error in %s at line %d: %s\n", __FILE__, \
                    __LINE__, cudaGetErrorString(err));                    \
            exit(EXIT_FAILURE);                                            \
        }                                                                  \
    }

// Host velocity fields, pressure, and divergence
double **h_u;                   // x-velocity on cell faces (ny x nx+1)
double **h_v;                   // y-velocity on cell faces (ny+1 x nx)
double **h_p;                   // pressure at cell centers (ny x nx)
double **h_div;                 // divergence (ny x nx)
double **h_u_center;            // x-velocity at cell centers (ny x nx)
double **h_v_center;            // y-velocity at cell centers (ny x nx)
double **h_velocity_magnitude;  // Velocity magnitude (ny x nx)
int *h_converged;               // Convergence flag

// Device 1D arrays
double *d_u;                   // x-velocity on cell faces
double *d_v;                   // y-velocity on cell faces
double *d_p;                   // pressure at cell centers
double *d_div;                 // divergence
double *d_u_next;              // temporary x-velocity
double *d_v_next;              // temporary y-velocity
double *d_u_center;            // x-velocity at cell centers
double *d_v_center;            // y-velocity at cell centers
double *d_velocity_magnitude;  // Velocity magnitude
int *d_converged;              // Convergence flag

// Function to convert float to half-precision float
uint16_t float_to_half(float f) {
    // Convert float to bits
    uint32_t f_bits = *((uint32_t *)&f);

    // Extract sign, mantissa and exponent
    uint16_t sign = (f_bits >> 31) & 0x01;
    uint16_t exp = (f_bits >> 23) & 0xFF;
    uint32_t mant = f_bits & 0x7FFFFF;

    // Handle special cases
    if (f == 0.0f) return 0;
    if (exp == 0xFF && mant == 0) return (sign << 15) | 0x7C00;  // Infinity
    if (exp == 0xFF && mant != 0) return (sign << 15) | 0x7E00;  // NaN

    // Calculate exponent for half precision
    int16_t half_exp = exp - 127 + 15;

    // Handle normal numbers
    if (half_exp >= 1 && half_exp <= 30) {
        // Normal number
        mant = mant >> 13;
        return (sign << 15) | (half_exp << 10) | mant;
    } else if (half_exp <= 0 && half_exp >= -10) {
        // Subnormal number (denormalized)
        // Shift mantissa to account for the exponent difference
        // Include the implied leading 1 bit for the mantissa
        mant = (mant | 0x800000) >> (14 - half_exp);
        return (sign << 15) | mant;
    } else if (half_exp > 30) {
        // Overflow to infinity
        return (sign << 15) | 0x7C00;
    } else {
        // Underflow to zero
        return (sign << 15);
    }
}

// Function to allocate memory for 2D arrays on host
double **allocate_2d_array(int rows, int cols) {
    double **arr = (double **)malloc(rows*sizeof(double *));
    double *data = (double *)calloc(rows*cols, s_d);
    for (int i = 0; i < rows; i++) {
        arr[i] = &data[i*cols];
    }
    return arr;
}

// Function to free memory for 2D arrays on host
void free_2d_array(double **arr) {
    free(arr[0]);  // Free the data block
    free(arr);     // Free the pointers
}

// Function to copy 2D host arrays to 1D device arrays
void copy_host_to_device() {
    // Copy u
    for (int j = 0; j < ny; j++) {
        CUDA_CHECK_ERROR(cudaMemcpy(d_u + j*(nx+1), h_u[j], (nx+1)*s_d,
                                    cudaMemcpyHostToDevice));
    }

    // Copy v
    for (int j = 0; j < ny+1; j++) {
        CUDA_CHECK_ERROR(cudaMemcpy(d_v + j*nx, h_v[j], nx*s_d,
                                    cudaMemcpyHostToDevice));
    }

    // Copy p
    for (int j = 0; j < ny; j++) {
        CUDA_CHECK_ERROR(cudaMemcpy(d_p + j*nx, h_p[j], nx*s_d,
                                    cudaMemcpyHostToDevice));
    }
}

// Function to copy 1D device arrays to 2D host arrays
void copy_device_to_host() {
    // Copy center velocities and magnitude
    for (int j = 0; j < ny; j++) {
        CUDA_CHECK_ERROR(cudaMemcpy(h_u_center[j], d_u_center + j*nx,
                                    nx*s_d,
                                    cudaMemcpyDeviceToHost));
        CUDA_CHECK_ERROR(cudaMemcpy(h_v_center[j], d_v_center + j*nx,
                                    nx*s_d,
                                    cudaMemcpyDeviceToHost));
        CUDA_CHECK_ERROR(cudaMemcpy(h_velocity_magnitude[j], d_velocity_magnitude + j*nx,
                                    nx*s_d,
                                    cudaMemcpyDeviceToHost));
    }
}

// CUDA kernel to apply boundary conditions
__global__ void apply_boundary_conditions_kernel(double *u, double *v,
                                                 int nx, int ny, int inlet_start, int inlet_end,
                                                 int outlet1_start, int outlet1_end, int outlet2_start,
                                                 int outlet2_end, int outlet3_start, int outlet3_end) {
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    int j = blockIdx.y*blockDim.y + threadIdx.y;

    // Left boundary (inlet): u = const, v = 0 at inlet; u = 0, v = 0 elsewhere
    if (i == 0 && j < ny) {
        if (j >= inlet_start && j <= inlet_end) {
            u[j*(nx+1) + 0] = 0.1; // Inlet velocity
        } else {
            u[j*(nx+1) + 0] = 0.0; // No-slip on rest of the left wall
        }
    }
    if (i == 0 && j <= ny) {
        v[j*nx + 0] = 0.0; // No y-velocity at left boundary
    }

    // Right boundary (outlets): zero-gradient for u at outlets; u = 0 elsewhere
    if (i == nx && j < ny) {
        if ((j >= outlet1_start && j <= outlet1_end) ||
            (j >= outlet2_start && j <= outlet2_end) ||
            (j >= outlet3_start && j <= outlet3_end)) {
            u[j*(nx+1) + nx] = u[j*(nx+1) + nx-1]; // Zero-gradient at outlets
        } else {
            u[j*(nx+1) + nx] = 0.0; // No-slip on rest of the right wall
        }
    }
    if (i == nx-1 && j <= ny) {
        if (j > 0 && j < ny) {
            v[j*nx + nx-1] = v[j*nx + nx-2]; // Zero-gradient for v at right boundary
        } else {
            v[j*nx + nx-1] = 0.0;
        }
    }

    // Top and bottom boundaries: no-slip condition
    if (j == 0 && i <= nx) {
        u[0*(nx+1) + i] = 0.0;     // Bottom
    }
    if (j == ny-1 && i <= nx) {
        u[(ny-1)*(nx+1) + i] = 0.0;  // Top
    }
    if (j == 0 && i < nx) {
        v[0*nx + i] = 0.0;     // Bottom
    }
    if (j == ny && i < nx) {
        v[ny*nx + i] = 0.0;    // Top
    }

    // Velocity clamping to prevent numerical instability
    if (i <= nx && j < ny) {
        if (u[j*(nx+1) + i] > 5.0) u[j*(nx+1) + i] = 5.0;
        if (u[j*(nx+1) + i] < -5.0) u[j*(nx+1) + i] = -5.0;
    }

    if (i < nx && j <= ny) {
        if (v[j*nx + i] > 5.0) v[j*nx + i] = 5.0;
        if (v[j*nx + i] < -5.0) v[j*nx + i] = -5.0;
    }
}

// CUDA kernel to compute the divergence in each cell
__global__ void compute_divergence_kernel(double *u, double *v, double *div,
                                          int nx, int ny, double dx,
                                          double dy) {
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    int j = blockIdx.y*blockDim.y + threadIdx.y;

    if (i < nx && j < ny) {
        div[j*nx + i] = (u[j*(nx+1) + i+1] - u[j*(nx+1) + i]) / dx +
                          (v[(j+1)*nx + i] - v[j*nx + i]) / dy;
    }
}

// CUDA kernel to update velocities based on Navier-Stokes equation
__global__ void update_velocities_kernel(double *u, double *v, double *p,
                                         double *u_next, double *v_next, int nx,
                                         int ny, double dx, double dy,
                                         double dt, double nu) {
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    int j = blockIdx.y*blockDim.y + threadIdx.y;

    // Internal cells for u (excluding boundaries)
    if (i >= 1 && i < nx && j >= 1 && j < ny-1) {
        // Calculate averages for u at cell centers
        double u_i__j = 0.5*(u[j*(nx+1) + i-1] + u[j*(nx+1) + i]);
        double u_i_plus1__j =
            0.5*(u[j*(nx+1) + i] + u[j*(nx+1) + i+1]);

        // Calculate uv product terms (Eq. uv-average)
        double uv_i_plushalf__j_minushalf =
            0.25*(u[(j-1)*(nx+1) + i] + u[j*(nx+1) + i]) *
            (v[j*nx + i-1] + v[j*nx + i]);
        double uv_i_plushalf__j_plushalf =
            0.25*(u[j*(nx+1) + i] + u[(j+1)*(nx+1) + i]) *
            (v[(j+1)*nx + i-1] + v[(j+1)*nx + i]);

        // Implement u-momentum equation (Eq. u-finite-diff)
        u_next[j*(nx+1) + i] =
            u[j*(nx+1) + i] + dt * (
                - (u_i_plus1__j*u_i_plus1__j - u_i__j*u_i__j) / dx
                - (uv_i_plushalf__j_plushalf - uv_i_plushalf__j_minushalf) / dy +
                - (p[j*nx + i] - p[j*nx + i-1]) / dx
                + nu*(
                    (u[j*(nx+1) + i+1] - 2*u[j*(nx+1) + i] + u[j*(nx+1) + i-1]) / (dx*dx)
                    + (u[(j+1)*(nx+1) + i] - 2*u[j*(nx+1) + i] + u[(j-1)*(nx+1) + i]) / (dy*dy)
                )
            );
    }

    // Internal cells for v (excluding boundaries)
    if (i >= 1 && i < nx-1 && j >= 1 && j < ny) {
        // Calculate averages for v at cell centers
        double v_i__j = 0.5*(v[(j-1)*nx + i] + v[j*nx + i]);
        double v_i__j_plus1 = 0.5*(v[j*nx + i] + v[(j+1)*nx + i]);

        // Calculate uv product terms (Eq. uv-average)
        double uv_i_minushalf__j_plushalf =
            0.25*(u[(j-1)*(nx+1) + i] + u[j*(nx+1) + i]) *
            (v[j*nx + i-1] + v[j*nx + i]);
        double uv_i_plushalf__j_plushalf =
            0.25*(u[(j-1)*(nx+1) + i+1] + u[j*(nx+1) + i+1]) *
            (v[j*nx + i] + v[j*nx + i+1]);

        // Implement v-momentum equation (Eq. v-finite-diff)
        v_next[j*nx + i] =
            v[j*nx + i] + dt * (
                - (v_i__j_plus1*v_i__j_plus1 - v_i__j*v_i__j) / dy
                - (uv_i_plushalf__j_plushalf - uv_i_minushalf__j_plushalf) / dx +
                - (p[j*nx + i] - p[(j-1)*nx + i]) / dy
                + nu*(
                    (v[j*nx + i+1] - 2*v[j*nx + i] + v[j*nx + i-1]) / (dx*dx)
                    + (v[(j+1)*nx + i] - 2*v[j*nx + i] + v[(j-1)*nx + i]) / (dy*dy)
                )
            );
    }
}

// CUDA kernel to copy the updated velocities back to the main velocity arrays
__global__ void update_velocities_final_kernel(double *u, double *v,
                                               double *u_next, double *v_next,
                                               int nx, int ny) {
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    int j = blockIdx.y*blockDim.y + threadIdx.y;

    if (i >= 1 && i < nx && j >= 1 && j < ny-1) {
        u[j*(nx+1) + i] = u_next[j*(nx+1) + i];
    }

    if (i >= 1 && i < nx-1 && j >= 1 && j < ny) {
        v[j*nx + i] = v_next[j*nx + i];
    }
}

// CUDA kernel to perform pressure correction iterations (Red-Black - Red Phase)
__global__ void pressure_correction_kernel_red(double *u, double *v, double *p,
                                            double *div, int nx,
                                            int ny, double dx, double dy,
                                            double dt, double beta,
                                            double div_tolerance,
                                            int *converged) {
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    int j = blockIdx.y*blockDim.y + threadIdx.y;

    if (i < nx && j < ny && (i + j) % 2 == 0) { // Process only red cells
        if (fabs(div[j*nx + i]) > div_tolerance) {
            atomicAnd(converged, 0);

            double delta_p = -beta*div[j*nx + i];
            p[j*nx + i] += delta_p * 0.7;

            // Adjust velocity components (direct assignment for red phase)
            if (i+1 <= nx) u[j*(nx+1) + i+1] += 0.5*dt/dx * delta_p;
            if (i >= 0) u[j*(nx+1) + i] -= 0.5*dt/dx * delta_p;
            if (j+1 <= ny) v[(j+1)*nx + i] += 0.5*dt/dy * delta_p;
            if (j >= 0) v[j*nx + i] -= 0.5*dt/dy * delta_p;
        }
    }
}

// CUDA kernel to perform pressure correction iterations (Red-Black - Black Phase)
__global__ void pressure_correction_kernel_black(double *u, double *v, double *p,
                                            double *div, int nx,
                                            int ny, double dx, double dy,
                                            double dt, double beta,
                                            double div_tolerance,
                                            int *converged) {
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    int j = blockIdx.y*blockDim.y + threadIdx.y;

    if (i < nx && j < ny && (i + j) % 2 != 0) { // Process only black cells
        if (fabs(div[j*nx + i]) > div_tolerance) {
            atomicAnd(converged, 0);

            double delta_p = -beta*div[j*nx + i];
            p[j*nx + i] += delta_p * 0.7;

            // Adjust velocity components (direct assignment for black phase)
            if (i+1 <= nx) u[j*(nx+1) + i+1] += 0.5*dt/dx * delta_p;
            if (i >= 0) u[j*(nx+1) + i] -= 0.5*dt/dx * delta_p;
            if (j+1 <= ny) v[(j+1)*nx + i] += 0.5*dt/dy * delta_p;
            if (j >= 0) v[j*nx + i] -= 0.5*dt/dy * delta_p;
        }
    }
}

// CUDA kernel to calculate velocities at cell centers and magnitude
__global__ void calculate_center_velocities_and_magnitude_kernel(
    double *u, double *v, double *u_center, double *v_center,
    double *velocity_magnitude, int nx, int ny) {
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    int j = blockIdx.y*blockDim.y + threadIdx.y;

    if (i < nx && j < ny) {
        u_center[j*nx + i] = 0.5*(u[j*(nx+1) + i] + u[j*(nx+1) + i+1]);
        v_center[j*nx + i] = 0.5*(v[j*nx + i] + v[(j+1)*nx + i]);
        velocity_magnitude[j*nx + i] =
            sqrt(u_center[j*nx + i]*u_center[j*nx + i] +
                 v_center[j*nx + i]*v_center[j*nx + i]);
    }
}

// Function to write the current state to the binary file
void write_state_to_binary(FILE *fp_u_center, FILE *fp_v_center,
                           FILE *fp_magnitude) {
    for (int j = 0; j < ny; j++) {
        for (int i = 0; i < nx; i++) {
            uint16_t half_val = float_to_half((float)h_u_center[j][i]);
            fwrite(&half_val, s_i16, 1, fp_u_center);
        }
    }

    for (int j = 0; j < ny; j++) {
        for (int i = 0; i < nx; i++) {
            uint16_t half_val = float_to_half((float)h_v_center[j][i]);
            fwrite(&half_val, s_i16, 1, fp_v_center);
        }
    }

    for (int j = 0; j < ny; j++) {
        for (int i = 0; i < nx; i++) {
            uint16_t half_val =
                float_to_half((float)h_velocity_magnitude[j][i]);
            fwrite(&half_val, s_i16, 1, fp_magnitude);
        }
    }
}

// Function to write metadata to a JSON file
void write_metadata_to_json(const char *filename, double compute_time_seconds, double total_time_seconds) {
    FILE *fp = fopen(filename, "w");
    if (fp == NULL) {
        perror("Error opening file");
        return;
    }

    fprintf(fp, "{\n");
    fprintf(fp, "    \"length_x\": %f,\n", length_x);
    fprintf(fp, "    \"length_y\": %f,\n", length_y);
    fprintf(fp, "    \"nx\": %d,\n", nx);
    fprintf(fp, "    \"ny\": %d,\n", ny);
    fprintf(fp, "    \"dx\": %f,\n", dx);
    fprintf(fp, "    \"dy\": %f,\n", dy);
    fprintf(fp, "    \"dt\": %f,\n", dt);
    fprintf(fp, "    \"nu\": %f,\n", nu);
    fprintf(fp, "    \"Re\": %f,\n", Re);
    fprintf(fp, "    \"div_tolerance\": %e,\n", div_tolerance);
    fprintf(fp, "    \"beta0\": %f,\n", beta0);
    fprintf(fp, "    \"max_iterations\": %d,\n", max_iterations);
    fprintf(fp, "    \"total_time\": %f,\n", total_time);
    fprintf(fp, "    \"beta\": %f,\n", beta);
    fprintf(fp, "    \"inlet_start_j\": %d,\n", inlet_start);
    fprintf(fp, "    \"inlet_end_j\": %d,\n", inlet_end);
    fprintf(fp, "    \"outlet1_start_j\": %d,\n", outlet1_start);
    fprintf(fp, "    \"outlet1_end_j\": %d,\n", outlet1_end);
    fprintf(fp, "    \"outlet2_start_j\": %d,\n", outlet2_start);
    fprintf(fp, "    \"outlet2_end_j\": %d,\n", outlet2_end);
    fprintf(fp, "    \"outlet3_start_j\": %d,\n", outlet3_start);
    fprintf(fp, "    \"outlet3_end_j\": %d,\n", outlet3_end);
    fprintf(fp, "    \"data_dtype\": \"float16\",\n");
    fprintf(fp, "    \"output_interval_in_c_steps\": %d,\n",
            (int)(total_time / dt) / max_number_of_frames);
    fprintf(fp, "    \"num_frames_output\": %d,\n",
            ((int)(total_time / dt) /
             ((int)(total_time / dt) / max_number_of_frames)));
    fprintf(fp, "    \"total_compute_time_seconds\": %f,\n",
            compute_time_seconds);
    fprintf(fp, "    \"total_time_seconds\": %f,\n",
            total_time_seconds);
    fprintf(fp, "    \"parallelization\": \"CUDA_RedBlack\"\n");

    fprintf(fp, "}");
    fclose(fp);
}

int main() {
    clock_t total_start_time = clock();
    double total_compute_time_seconds = 0.0;

    // Allocate host memory
    h_u = allocate_2d_array(ny, nx+1);
    h_v = allocate_2d_array(ny+1, nx);
    h_p = allocate_2d_array(ny, nx);
    h_div = allocate_2d_array(ny, nx);
    h_u_center = allocate_2d_array(ny, nx);
    h_v_center = allocate_2d_array(ny, nx);
    h_velocity_magnitude = allocate_2d_array(ny, nx);

    // Initialize flow: zero velocity everywhere
    for (int j = 0; j < ny; j++) {
        for (int i = 0; i <= nx; i++) {
            h_u[j][i] = 0.0;
        }
    }
    for (int j = 0; j <= ny; j++) {
        for (int i = 0; i < nx; i++) {
            h_v[j][i] = 0.0;
        }
    }

    // Allocate device memory
    CUDA_CHECK_ERROR(cudaMalloc((void **)&d_u, ny*(nx+1)*s_d));
    CUDA_CHECK_ERROR(cudaMalloc((void **)&d_v, (ny+1)*nx*s_d));
    CUDA_CHECK_ERROR(cudaMalloc((void **)&d_p, ny*nx*s_d));
    CUDA_CHECK_ERROR(cudaMalloc((void **)&d_div, ny*nx*s_d));
    CUDA_CHECK_ERROR(cudaMalloc((void **)&d_u_next, ny*(nx+1)*s_d));
    CUDA_CHECK_ERROR(cudaMalloc((void **)&d_v_next, (ny+1)*nx*s_d));
    CUDA_CHECK_ERROR(cudaMalloc((void **)&d_u_center, ny*nx*s_d));
    CUDA_CHECK_ERROR(cudaMalloc((void **)&d_v_center, ny*nx*s_d));
    CUDA_CHECK_ERROR(cudaMalloc((void **)&d_velocity_magnitude, ny*nx*s_d));
    CUDA_CHECK_ERROR(cudaMalloc((void **)&d_converged, s_i));

    // Initialize device memory
    CUDA_CHECK_ERROR(cudaMemset(d_u, 0, ny*(nx+1)*s_d));
    CUDA_CHECK_ERROR(cudaMemset(d_v, 0, (ny+1)*nx*s_d));
    CUDA_CHECK_ERROR(cudaMemset(d_p, 0, ny*nx*s_d));
    CUDA_CHECK_ERROR(cudaMemset(d_div, 0, ny*nx*s_d));
    CUDA_CHECK_ERROR(cudaMemset(d_u_next, 0, ny*(nx+1)*s_d));
    CUDA_CHECK_ERROR(cudaMemset(d_v_next, 0, (ny+1)*nx*s_d));
    CUDA_CHECK_ERROR(cudaMemset(d_u_center, 0, ny*nx*s_d));
    CUDA_CHECK_ERROR(cudaMemset(d_v_center, 0, ny*nx*s_d));
    CUDA_CHECK_ERROR(cudaMemset(d_velocity_magnitude, 0, ny*nx*s_d));

    // Copy data from host to device
    copy_host_to_device();

    // Define CUDA grid and block dimensions
    dim3 blockSize(16, 16);
    dim3 gridSize((nx + blockSize.x) / blockSize.x,
                  (ny + blockSize.y) / blockSize.y);

    // Open output files
    FILE *fp_u_center = fopen("u_center_data.bin", "wb");
    FILE *fp_v_center = fopen("v_center_data.bin", "wb");
    FILE *fp_magnitude = fopen("velocity_magnitude_data.bin", "wb");

    if (fp_u_center == NULL || fp_v_center == NULL || fp_magnitude == NULL) {
        perror("Error opening binary files");
        return 1;
    }

    int num_time_steps = (int)(total_time / dt);
    int output_interval = num_time_steps / max_number_of_frames;
    if (output_interval == 0) output_interval = 1;

    // Main time loop
    for (int t = 0; t < num_time_steps; t++) {
        clock_t step_start_time = clock();

        // Update velocities
        update_velocities_kernel<<<gridSize, blockSize>>>(
            d_u, d_v, d_p, d_u_next, d_v_next, nx, ny, dx, dy, dt, nu);
        // CUDA_CHECK_ERROR(cudaGetLastError());
        CUDA_CHECK_ERROR(cudaDeviceSynchronize());

        // Copy updated velocities
        update_velocities_final_kernel<<<gridSize, blockSize>>>(
            d_u, d_v, d_u_next, d_v_next, nx, ny);
        // CUDA_CHECK_ERROR(cudaGetLastError());
        CUDA_CHECK_ERROR(cudaDeviceSynchronize());

        // Pressure correction iterations
        for (int iter = 0; iter < max_iterations; iter++) {
            // Compute divergence
            compute_divergence_kernel<<<gridSize, blockSize>>>(d_u, d_v, d_div,
                                                               nx, ny, dx, dy);
            // CUDA_CHECK_ERROR(cudaGetLastError());
            CUDA_CHECK_ERROR(cudaDeviceSynchronize());

            // Initialize convergence flag to 1
            int h_converged = 1;
            CUDA_CHECK_ERROR(cudaMemcpy(d_converged, &h_converged, s_i,
                                        cudaMemcpyHostToDevice));

            // Apply pressure correction (Red-Black)
            pressure_correction_kernel_red<<<gridSize, blockSize>>>(
                d_u, d_v, d_p, d_div, nx, ny, dx, dy, dt, beta,
                div_tolerance, d_converged);
            // CUDA_CHECK_ERROR(cudaGetLastError());
            CUDA_CHECK_ERROR(cudaDeviceSynchronize());

            pressure_correction_kernel_black<<<gridSize, blockSize>>>(
                d_u, d_v, d_p, d_div, nx, ny, dx, dy, dt, beta,
                div_tolerance, d_converged);
            // CUDA_CHECK_ERROR(cudaGetLastError());
            CUDA_CHECK_ERROR(cudaDeviceSynchronize());

            // Check if converged
            CUDA_CHECK_ERROR(cudaMemcpy(&h_converged, d_converged, s_i,
                                        cudaMemcpyDeviceToHost));

            if (h_converged) {
                break;
            }
        }

        // Apply boundary conditions
        apply_boundary_conditions_kernel<<<gridSize, blockSize>>>(
            d_u, d_v, nx, ny, inlet_start, inlet_end, outlet1_start, outlet1_end, outlet2_start, outlet2_end, outlet3_start, outlet3_end);
        // CUDA_CHECK_ERROR(cudaGetLastError());
        CUDA_CHECK_ERROR(cudaDeviceSynchronize());

        // Calculate center velocities and magnitude
        calculate_center_velocities_and_magnitude_kernel<<<gridSize,
                                                           blockSize>>>(
            d_u, d_v, d_u_center, d_v_center, d_velocity_magnitude, nx, ny);
        // CUDA_CHECK_ERROR(cudaGetLastError());
        CUDA_CHECK_ERROR(cudaDeviceSynchronize());

        clock_t step_end_time = clock();
        total_compute_time_seconds +=
            (double)(step_end_time - step_start_time) / CLOCKS_PER_SEC;

        // Output results at specified intervals
        if (t % output_interval == 0) {
            // Copy results from device to host for output
            copy_device_to_host();

            // Write to binary files
            write_state_to_binary(fp_u_center, fp_v_center, fp_magnitude);
        }
    }

    // Copy final results from device to host
    copy_device_to_host();

    // Close output files
    fclose(fp_u_center);
    fclose(fp_v_center);
    fclose(fp_magnitude);

    // Calculate total elapsed time
    clock_t total_end_time = clock();
    double total_time_seconds =
        (double)(total_end_time - total_start_time) / CLOCKS_PER_SEC;

    // Write simulation metadata
    write_metadata_to_json("simulation_metadata.json",
                           total_compute_time_seconds, total_time_seconds);

    // Free device memory
    cudaFree(d_u);
    cudaFree(d_v);
    cudaFree(d_p);
    cudaFree(d_div);
    cudaFree(d_u_next);
    cudaFree(d_v_next);
    cudaFree(d_u_center);
    cudaFree(d_v_center);
    cudaFree(d_velocity_magnitude);
    cudaFree(d_converged);

    // Free host memory
    free_2d_array(h_u);
    free_2d_array(h_v);
    free_2d_array(h_p);
    free_2d_array(h_div);
    free_2d_array(h_u_center);
    free_2d_array(h_v_center);
    free_2d_array(h_velocity_magnitude);

    return 0;
}
